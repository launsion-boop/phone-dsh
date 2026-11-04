<!-- SPDX-License-Identifier: MIT -->
# Android 适配回执（2026-10-31）

本文件是 PR 描述的直接来源。**每个结论都标了证据等级**，未达等级的一律写 `not-verified`，不按「应该能行」记。

## 证据等级

| 等级 | 含义 |
| --- | --- |
| `jvm` | 纯 JVM 单测/集成测，无设备 |
| `emulator` | 模拟器上跑通（API 35 = `emulator-5554`，API 33 = `emulator-5556`） |
| `device` | 真机才成立 —— **本轮全部未做**，PR 后补 |
| `not-verified` | 没有证据，且不得在产品文案里声称 |

## 1. 交付物

| 模块 | 形态 | main 行数 | 测试 |
| --- | --- | ---: | --- |
| `:platform` | 纯 JVM SPI（6 接口 + 测试替身） | 877 | 18 |
| `:platform-android` | SPI 的 Android 实现 | 1,030 | 11 + 24 instrumented（两个 API 各 12） |
| `:core` | wire(JNI) + log(WAL) + agentcore | 6,244 | 125 |
| `:net` | loopback + gateway | 2,941 | 135 |
| `:controller` | D14 九状态机 | 1,474 | 67（含 16 条扰动夹具） |
| `:engine` | 单 WebView 宿主 | 2,203 | 51 + 2 instrumented |
| `:dsh` | 门面 + host HELLO + VFS sink + exec 桥 + 后台 | 6,895 | 80 + 12 instrumented（API 33） |
| `:lib` | UI parity（9 页 + 6 签名面 + UiState 投影） | 3,878 | 192 |
| `:testkit` | 第三 runner（场景 + 轨迹归一化 + 回合驱动） | 3,752 | 108 + 1 instrumented |
| `:domain` | P6 域名存储 + 设备能力 | 1,812 | 58 + 28 instrumented（两个 API） |
| `:app` | probe app（单屏 + 真实 host） | 568 | — |

**合计**：Android Kotlin main 约 **29.9K 行**、单测 **17.3K 行**、instrumented 1.2K 行；Rust `shell/crates` **26.8K 行**；契约层 `spec/` 219 文件 / 136 金标。

测试总览（`android/tools/test-count.sh`）：**839+ tests, 0 failing**（不含 instrumented）。instrumented 另计 67 条，分布在 `:engine` / `:dsh` / `:domain` / `:platform-android` / `:testkit`，在 API 33 与 API 35 上都跑过。

## 2. 能力与证据等级

| 能力 | 证据 | 等级 |
| --- | --- | --- |
| proto 1 帧编解码（33 条金标） | Kotlin → JNI → Rust 逐字节 | `jvm` |
| WAL 格式 / 恢复 / 撕裂判定 / D18 fsync 顺序 | 86+ 测试、2 条金标逐字节、精确 SPI 事件序列 | `jvm` |
| WAL 配额与压缩（§9） | 200 条记录跑过 24 KiB 上限，压缩后冷恢复逐字节还原 | `jvm` |
| D14 九状态机 | 16/16 扰动夹具 + 迁移矩阵 | `jvm` |
| gateway 六类安全规则 | **28 条金标向量全过**（含 `body_sha256` 字节钉死） | `jvm` |
| loopback origin（随机端口 / token / D22 launch cookie） | 51 测试 | `jvm`（launch cookie 另有 `emulator` 实证） |
| boot → 页面 → 通道 → HELLO 上屏 | `run-demo.sh` + 截图 | `emulator` |
| renderer 死亡 → 重建 → 恢复 | `inject-renderer-death.sh`，7/7 断言，可反复 | `emulator` |
| 宿主 HELLO 三条 caps 为真 | `wal/1`（真 VFS_MUT→WAL→ACK）、`exec/1`（`phone info` 真执行） | `emulator` |
| 后台：FGS / UIDT / 墓碑 / 通知降级 | 12 条 instrumented，API 33 与 35 对照 | `emulator` |
| 域名存储 / 设备能力 | 同一份 22 条 contract 在 fake 与真 SQLite 上各跑一遍 | `jvm` + `emulator` |
| UI：UiState 投影 | **5/5 轨迹夹具逐字节**（含 real-difference 那组保持差异） | `jvm` |
| UI：9 个页面 | 192 测试，token 引用由机器对账 | `jvm` |
| 第三 runner | 4 个真实场景跑出真实 exit code；6 条命令如实 `PENDING_HOST` | `jvm` |
| **一个完整回合**（prompt→tool→result→end） | 设备上跑通，**但驱动在 `:testkit`**，见 §4 | `emulator`（测试面） |
| **进程被杀矩阵**（force-stop / kill -9 / am kill / trim / VM 终止） | 7 格 × 杀前/杀后/恢复后三步，WAL/journal 逐帧 CRC 校验，见 [android-p6-kill-matrix-2026-11-01.md](android-p6-kill-matrix-2026-11-01.md) §1 | `emulator` |
| **持久化承诺**（level-1 / 尾部可检出） | 进程级 5 种杀法零丢失；torn tail 注入 + 真实 NUL 半截行均可检出；**level-2 降级**，见 [决策记录](../design/android-durability-decision-2026-11-01.md) | `emulator` |
| **reclaim token 可用性矩阵** | 锁屏设/改/清密码、升级安装、卸载重装、迁移恢复、Auto Backup 共 8 格，见 [android-p6-kill-matrix-2026-11-01.md](android-p6-kill-matrix-2026-11-01.md) §2 | `emulator`（保险库原语；无 handoff 端点） |

## 3. 门禁

```
structure_check                     9 项全过
spec_golden --full                  73 文件 / 0 error
gateway_check                       28 向量 / 0 error
platform_check                      23 条白名单 / 0 failure
android/tools unittest              19 个
:app:assembleRelease                BUILD SUCCESSFUL（42.6 MB，R8 + .so strip）
```

`structure_check` 的 9 项里，这一轮新增了两条：`nested-comments`（Kotlin 嵌套注释会吞文件，两个车道为此各花 20 分钟）与 `kotlin-stubs`（禁占位代码）。另有独立脚本 `check-native-alignment.py`（16 KB 页对齐，带会红的 unittest）。

## 4. 未完成 / 已知缺口（逐条）

### 4.1 demo 第 6 条：**在 app 主面通**（模型为脚本）

`bash android/tools/run-app-turn.sh` 在 emulator-5554 上 12 条断言全过：

```
PASS turn_started / tool_call / tool_result / turn_ended
PASS turn_ended(reason=completed) / App reported completion
PASS host sent API_REQ / received API_RES / received API_END
PASS App /v1/http allowed the exact origin / denied an unlisted origin
PASS event order: turn_started tool_call tool_result turn_ended
```

app 自己发 `API_REQ`、收 `API_RES`/`API_END`，四个事件来自真实 `session/follow` 流；`phone info` 由 host 真执行（`EXEC_REQ` → `EXEC_EVT` exit 0，stdout 是真设备 JSON）。base URL 只经 `pageParams["env"]` 注入（`ProbeLaunchConfig.workerEnvironment()`），app 日志里没有该值；allowlist 只由本次 launch 的 exact origin 生成，unlisted origin 在接触 transport 之前被拒（403）。

**三条必须同时读的限定**：

1. **模型是脚本**（`android/tools/scripted-model-upstream.py`，无推理、无真实 key，env 里是占位串）。"脚本化 upstream"本就是 demo 的定义，但这意味着**这条链路没有验证过真实推理**。
2. **模型流量没有走 `/v1/http`**：DSH 的 provider 直接在 `DEEPSEEK_BASE_URL` 后拼 `/v1/messages`，所以 base URL 指向脚本上游（经 `adb reverse`）。`/v1/http` 的挂载只由 app 自己的诊断探针验证（200 / 403）。让模型流量也经 `/v1/http` 需要 DSH host 侧 fetch 改道，属未决设计。
3. **~~JOURNAL 在 app 里仍是 off~~ — 已修复。** 复跑证据（同一脚本、同一设备）：
   ```
   PDSHHost: journal: on (0 session(s), fsync before every ACK)
   PDSHHost: journal: appended jseq 1/2/3 ... (450/928/1403 bytes)
   journal: off                  → 0 次
   durability ack wait timed out  → 0 次
   1 channel open, 0 restarts（45 s 观察窗）
   ```
   同时接上了另两处主面缺口：`EXEC_CTL 0x22` 分发（坏帧回 `BAD_PAYLOAD` 并以 ERROR 关闭；`Applied`/`Refused` 由 live `EXEC_EVT` 流负责，不重复发）与 `HostExec` 改用 `FileRequestLedger`（设备上 `files/xl/exec/<idem_key>.json` 与 `files/xl/journal/...` 都实际落盘）。

   一处**诚实的范围说明**：本回合本身约 4 秒，45 秒观察窗覆盖的是「最后一次 append 之后的 30 秒 durability 窗口」，不是一个超过 30 秒的回合。**超长回合未被直接验证。**

### 4.2 WAL / 持久化

配额超限的 `Failed` **未接 controller**（`VfsSink` 只 log + close + rethrow，没触发 `RECORD_FAILURE`）；`§9` 的入站 seq 强制、32 MiB flow control、2 ms group commit 未做。

**`level-2` 掉电承诺：已按 R1 降级，不再是挂在回执上的 `NOT_VERIFIED` 一句话。** 决定记录见
[android-durability-decision-2026-11-01.md](../design/android-durability-decision-2026-11-01.md)：本轮**没有**真机台架
（`adb devices -l` 只有模拟器；AVD 数据分区是宿主上的 QCOW2，`adb emu kill` 杀的是虚拟机，不是给存储断电），
所以 `Durability.level()` 保持 `LEVEL_2_POWER_LOSS_UNVERIFIED`，`supportsLevel2Claim()` 为 false，
对外承诺收窄为「**进程被杀不丢 + 尾部可检出**」。机制侧（D18 三步 fsync / manifest 原子替换）不动。

同轮证据（[kill 矩阵](android-p6-kill-matrix-2026-11-01.md)）：进程级 5 种杀法 × 两种时机，杀前/杀后/恢复后的
WAL 记录数、journal 记录数、session 行数逐项相等，0 torn；`adb emu kill`（最接近掉电的终止方式）暴露 BUG-1
（0 字节未列段 → `WAL_CORRUPT` → 工作区不可用），已单独报告，见 §6。

### 4.3 exec

in-flight 重复 `idem_key` 回 `in_flight` 而非 join；`EXEC_CTL 0x22` 未处理；持久 ledger 仍是内存版；无 live event store。

### 4.4 P6 平台层

`schema` 语义拆分（declared manifest vs measured Android facts）待 spec 决策；`updated_at` 是 hybrid logical stamp，跨端共享 golden 前需统一；无 tolerant decoder（连接器要用）。

### 4.5 UI

页面级几何 token 缺（33 条 geometry 只覆盖 6 个签名面，页面复用并标 `unverified geometry`）；截图基线未做（不应由 Robolectric 假字体度量生成）；`Colors.background` 是 `unmeasured`。

### 4.6 契约层

`turn-event` kind 未被使用；`/v1/http` 的响应脱敏在真实现里必须走 `SensitiveResponseBody`（测试面前置只做转发）；refused-redirect 的对外表面仍不可观测（无 `expect.status`）。

### 4.7 P6：kill 矩阵 / 掉电 / reclaim（2026-11-01）

证据：[android-p6-kill-matrix-2026-11-01.md](android-p6-kill-matrix-2026-11-01.md)；决定：[android-durability-decision-2026-11-01.md](../design/android-durability-decision-2026-11-01.md)。

**已闭**：进程级 5 种杀法 × 两种时机的三步证据全绿（0 torn / 0 丢失 / 会话形状与杀法一致）；torn tail 可检出（注入 + 真实 NUL 半截行）；
reclaim token 的锁屏设/改/清、升级安装、迁移恢复（`Unreadable` fail-closed）、Auto Backup（`Backup is not allowed`）全部实测；
`level-2` 由「固定 NOT_VERIFIED」改成**有决策记录的降级**。

**仍开**：

- **BUG-1（阻断，写权限外）**：未列入 manifest 的 **0 字节段**被判 `WAL_CORRUPT` → `wal/1 off` → Worker 拒启动 → 工作区永久不可用。
  `adb emu kill` 后必现；删掉空文件即恢复（`next_mseq=438, acked_mseq=437`）。要 `spec/v1/wal.md` §7.2/§10 与 `:core` 恢复路径的所有者定夺。
- **真实 LMK 杀无法在模拟器复现**：`am send-trim-memory COMPLETE` 只投递回调（实测 pid 前后不变），本轮用后台 `am kill` 作同类证据并明确标注。
- **锁屏矩阵需要真机复跑**：模拟器 `AndroidKeyStore` 是 `SOFTWARE`，认证绑定/StrongBox/OEM 实现都会改变 C1 的结论。
- **正式产品文案在 `:lib`（只读车道）**：本轮只在探针屏 footer 加了诚实声明，产品面需 UI 车道同步。

## 5. PR 后要补的真机证据

| 能力 | 为什么必须真机 |
| --- | --- |
| level-2 掉电承诺（**已降级，未承诺**） | f2fs/ext4 + 设备 write cache 的真实掉电行为，模拟器不可代表；升回 level-2 的台架与验收条件写在决策记录 §7 |
| OEM 查杀矩阵 | 华为 PowerGenie / 小米省电 / OPPO Athena 只在真机存在 |
| 华为 WebView 内核 | `com.huawei.webview` ≈ Chromium 99，不可 Play 更新；模拟器是 Google WebView 124 |
| 32 位 ABI | wasm `memory.grow` 在 32 位 provider 上易碎 |
| TEE / StrongBox | 模拟器上 `AndroidSecureStore.level` 实测是 `SOFTWARE` |
| FGS 后台起服被拒 / 6h `onTimeout` | 需要真后台与 6 小时以上 |
| API 26–32 回退 | 无镜像 |

## 6. 这一轮修掉的真问题（不是新功能）

- **URL 泄露路径**：renderer 恢复失败的原因绕过了 `<url>` 擦除
- **跨平台字节分歧**：Kotlin 按 UTF-16 code unit 排序，规范要 code point（只在 emoji key 上暴露）
- **两个参考实现 bug**：Python 轨迹归一化器把平台规则按位置套错行；request-id 的 UUID 检测顺序颠倒
- **Kotlin 嵌套注释**：KDoc 里的 `wal/*.xlwal` 吞掉整个文件（已做成机器检查）
- **一个零断言的绿测试**：UIDT 在 API<34 提前 `return`，JUnit 记 PASS
- **APK 里 bundle 打两份**：且 AGP 会把 `*.tar.gz` 解压改名，字节都变了
- **发布面缺 R8 规则**：`:lib` 的 AAR 没带 keep 规则，下游混淆后 JNI 会 `UnsatisfiedLinkError`
- **三个脚本地雷**：`JAVA_HOME` stub 让 Gradle 跑 27 分钟零产物；双模拟器下设备不确定；headless AVD 上 `monkey` 必失败
- **torn-tail 记录被丢弃**（P6）：`:app` 构造 `WorkspaceLog` 时没传 sink，默认 `WalLogSink.NONE` 把 `wal.md` §10 要求的截断记录吞了
- **回合被杀后无报告**（P6）：`InterruptedTurnStore` 的零回调墓碑写好了却从没被 `:app` 写入；`kill -9` 后没有任何界面或日志说「上次回合中断」
- **`wal/1` off 时屏幕仍说「运行中」**（P6）：WAL 恢复失败 → Worker `PROTO_MISMATCH` 拒启动，探针屏却无横幅
- **reclaim token 读不出无界面**（P6）：`SecureLookup.Unreadable` 只在实现里正确 fail-closed，用户侧不可见
- **恢复窗口的活体 tar 会读到陈旧树**（P6，测量方法）：66 个条目只读到 32 个且 `journal/` 缺失；证据快照已改为「先 force-stop 再 tar」

精简审查净减 **1,471 行**（R1 −852 main / R2 −261 / R3 −117 / R4 −241），**断言一条没删**。

## 7. 结论

Android 侧从「零产品代码」到「12 个模块、839+ JVM 测试 + 67 instrumented、能在模拟器上 boot→HELLO→恢复→跑完一个真实回合（测试面）」。

**没有一条结论来自真机。** 回执里出现的每个 `emulator` 都应理解为「模拟器上成立，真机未知」。

## 9. 设备上的 shell 不是 host 的 shell（U1，真实测量）

第三 runner 现在能在**设备上**跑 catalog 场景（`CatalogOnDeviceTest`，4 条 instrumented + 1 条既有，5/5 通过）。

**先回答一个原本不确定的问题：Android app 沙箱允许 `ProcessBuilder` fork/exec 系统 shell。**

```
device: sdk=35 abi=arm64-v8a
/system/bin/sh exists=true canExecute=true
probe [sh -c echo hi]              -> started=true exit=0 output='hi'
probe [/system/bin/sh -c ...]      -> KSH=@(#)MIRBSD KSH R59 2020/10/31 / toybox 0.8.11-android
```

即：设备上的 `/system/bin/sh` 是 **mksh（MirBSD KSH R59）**，shell 内建命令由 mksh 提供，toybox 提供的是 applet 集。**这与 host 的 `bash 3.2.57` 是两个不同程序。**

### 逐条差异（同一场景、同一断言集）

| # | 命令 | JVM（bash） | 设备（mksh+toybox） | 是否影响断言 |
|---|---|---|---|---|
| 1 | 执行器身份 | `host-sh /bin/sh` = GNU bash 3.2.57 | `host-sh /system/bin/sh` = mksh R59 | 只影响 detail 文本 |
| 2 | `test "$(wc -l < numbers.txt)" -eq 300000` | exit **2**（bash 拒绝空操作数） | exit **1**（mksh 把 `""` 当 0） | **不影响**：两者非 0，断言行都是 `COMMAND_FAILED` |
| 3 | 同上 stderr | `integer expression expected` | `can't open numbers.txt` | 不影响 |
| 4 | `awk` 一行 | exit 1 | exit 1 | 相同 |
| 5 | `sed` 一行 | exit 1 | exit 1 | 相同（stderr 逐字相同） |
| 6 | `grep` 一行 | exit 2 | exit 2 | 相同（诊断逐字相同） |
| 7 | `if grep ...` 两行 | exit 0 | exit 0 | 相同 |

**最重要的观察是第 2 条**：exit 码不同（2 vs 1）、stderr 不同，但**断言的行分布完全相同**（1/0/4）。

也就是说：**如果只比较场景报告，这个平台差异是不可见的。** 只有逐命令比较 exit 码与 stderr 才看得见。这正是 U1 把「JVM 侧录制值 vs 设备实测值」逐条打印出来的价值。

反方向也成立：G2-C01 整体差异为空——**「shell 不是同一个程序」并不必然导致行为差异**，所以不能反过来假设「设备上一定不同」。

### 设备车道没做到的（如实记录）

- **没有真模型**：`ScriptedTurnDriver.completed()` 不写文件，所以依赖模型产出的文件断言按种子**诚实失败**（与 JVM 车道同一限制）。设备上没有「模型回合」证据。
- **没有 Worker console**：三个 pick 都不含 `no_console_error`，该断言在设备上未覆盖。
- **没有 restart 扰动**：`restart_recovered` 未在设备上执行。
- **只在 API 35 测**：`toybox 0.8.11` / `mksh R59` 的结论只对该镜像负责，`pdsh33` 未复测。

## 10. 收口数据（2026-10-31，最终树）

**全树 JVM 测试：1095 通过 / 0 失败 / 1 skipped。** 必须是 `--rerun-tasks` 那次的结果——
一次不带它的运行报 `BUILD SUCCESSFUL in 9s` 但 `10 executed, 266 up-to-date`，也就是
**一条断言都没跑**。最终数是 `276 actionable tasks: 276 executed`，221 个结果 XML 全部新鲜。

| 模块 | 测试 |
|---|---:|
| `:lib` | 287 |
| `:net` | 148 |
| `:dsh` | 148 |
| `:core` | 139 |
| `:testkit` | 108（1 skip） |
| `:domain` | 79 |
| `:controller` | 67 |
| `:engine` | 51 |
| `:shell` | 39 |
| `:platform` | 18 |
| `:platform-android` | 11 |
| **总计** | **1095** |

计时口径：每模块只计一个变体（`test` 或 `testDebugUnitTest`），不是 debug+release 之和。
`:app` 没有测试源。

**设备验收（emulator-5554，最终树）：12/12 断言通过，0 次 durability 超时。**

```
channel connections this run: 1
durability timeouts this run: 0 (restarting lines: 0)
journal observation: no durability timeout or channel reopen was observed inside the 45s watch
```

HELLO 的 caps 里实际出现 `accelerator:phone`、`accelerator:rg`、`accelerator:jaq`——两个 Rust
加速器（走 `pdsh-ffi` 的统一 C ABI）**在设备上真的被声明了**，不是只在代码里存在。

**静态门禁**：`structure_check` 9/9、`spec_golden --full` 73 文件 0 error、`gateway_check` 30 向量
0 error、`platform_check` 24 条白名单 0 failure、`ui_check` 38 geometry、`host_check` 41 文件 0 error、
`android/tools` 19 条检查器单测、`spec/*/tools` 185 条检查器单测全绿。

## 11. 这一轮抓到的六种「假绿」

没有一种是靠看结论发现的，全部靠看过程。

| # | 假绿 | 判据 |
|---|---|---|
| 1 | 零断言的 `return` 被 JUnit 记 PASS | 看断言数，换成 `assumeTrue` |
| 2 | lazy 未组合时的 `assertDoesNotExist` | 先 `performScrollToNode` 再断言 |
| 3 | `INCOMPLETE` 被读成 `PASS`（跳过了可选阶段） | CI 阶段区分两个词 |
| 4 | 「窗口覆盖了」被说成「跑过长回合」 | 回合实际 4 s，45 s 窗口只覆盖 timeout 窗口 |
| 5 | 「窗口内没观察到」当成「不存在」 | 必须说观察窗多长 |
| 6 | `BUILD SUCCESSFUL` 但 `10 executed / 266 up-to-date` | **看 executed 数** |

第 6 种最彻底：前五种是「跑了但没验」，它是「压根没跑」。

## 12. 一个没有任何测试能抓到的跨语言分歧（已修）

`spec/v1/trajectory.md` §7 的 nodeID 文法有五级，`.../event/<seq>` 与 `.../event/<seq>/<slot>`
是两级，且「every `parentID` names an existing node and is exactly one grammar level above its child」。

Android 的 `UiStateProjector` **从未产出 `turn-event` 节点**，slot 直接挂在 turn 上：

```
nodeID   = session/sess-001/turn/turn-0001/event/1/user-message   ← 声称有 event 父节点
parentID = session/sess-001/turn/turn-0001                        ← 指向 turn
```

**两边都绿**：`:lib` 的 pinned 期望由它自己钉，从不经过 `spec/v1/tools/trajectory_norm.py`。
修复后新增 26 个 `turn-event` 节点（6 个 case），并补了一条纯 JSON 的
`UiStateNodeIDGrammarTest`（7 条断言，按深度计算父节点），把这类漂移变成红灯。

修复连带暴露另两处**消费方假设**（`ChatScreenState` 用 `node.parentID` 当 turn 节点）：
回合永不关闭（`phase` 卡在 `RUNNING`）、**运行中的工具行渲染成 STOPPED**。
前者崩溃可见，后者是 UI 一致地说谎。三处都已修，`trajectory_norm` 也补上了「结构节点
`seq == 0`」这条它一直没查的规范要求。

## 13. 未解决：launch token 仍随 URL 下发（预构建 bundle 的约束）

**这不是 Android 移植的缺陷，是上游 bundle 接口的约束。** 已完整取证，结论是改不了。

链路（预构建、gitignored 的 worker bundle，只读）：

```
boot.js:64            new URLSearchParams(location.search)
boot.js:75,131        params.get('env') → parseJsonParam → env
boot.js:160-171       worker.postMessage({ t:'init', xl:{ token, env, ... } })
worker-entry.js:94671 initOptions(): token = xl.token, env = stringRecord(xl.env)
worker-entry.js:20415 installProcessGlobal({ env: { ...options.env } })
dsh-surface-phone/lib/index.js:2083-2084
                      const token = process.env.PDSH_DSH_LAUNCH_TOKEN ?? ""
                      if (token === "") throw new Error("...is required")
```

所以 `:engine` 若把 token 从 `?env=` 删掉，**surface-phone 直接 throw，worker 不会发 `XL_DSH_READY`，回合必挂**。

三条替代通道都不通：

| 通道 | 结论 |
|---|---|
| D22 的 `xl_launch_token` cookie | HttpOnly（`LaunchCookie.kt:50`），bundle 内 `grep -c "document\.cookie" boot.js worker-entry.js` = **0 0**，`grep xl_launch_token` 在 bundle 里 **0 命中** |
| `?token=` | 只映射到 `PDSH_CHANNEL_TOKEN`（`worker-entry.js:94788`），不喂 launch token，而且是更直接的 URL 泄露 |
| `/__boot__` | `worker.js:3263-3273` 只返回 `{ injections }`，不含 token |

**已缓解的部分**：

1. `boot.js:84-101` 在读取后立即 `history.replaceState` 抹掉 `env`/`token`（`BOOT_TRANSPORT_PARAMS`），所以暴露窗口 = `loadUrl` → boot.js 执行之间。stock `index.html` 没有在 deferred module 之前执行的 inline script，窗口内无人读取。
2. 日志侧的泄漏路径已修（见 §14）：`onConsoleMessage` 的 `sourceId` 与 `message`、页面 title、三个 JS 对话框 message 全部走 `EngineLogText.console()` 切掉 query。
3. env 里的 `DEEPSEEK_API_KEY` 现在是 **placeholder**（§15），不再是真凭据。

**要彻底移除必须改预构建 bundle**：document-start 注入（宿主在页面脚本执行前设置变量）、或 bundle 改为从 cookie / 一次性端点取。两者都在上游，不在本移植范围。

## 14. 一个真实的日志泄漏路径（已修 + 已有回归守卫的说明）

`WebViewEngine` 会记录页面可控文本，其中 inline page script 的 `sourceId` **就是文档 URL**（含 `?env=`）。

**关键更正：stock bundle 的自然运行不触发它。** bundle 里所有 console 都来自外部脚本 `worker-entry.js`，`sourceId` 是脚本 URL。只有页面里出现 inline `<script>` 时才会走这条路径——所以「12/12 断言全过」本来就不是这个漏洞的证据。

复现方式（真机真 WebView，设备上的 bundle 副本插一行 inline script）：

```
console LOG: Z3_PARSER http://127.0.0.1:33539/?image=…&env=%7B…%22PDSH_DSH_LAUNCH_TOKEN%22%3A%22<redacted>%22%7D (…:5)
```

修复后同一触发：

```
console LOG: Z3_PARSER http://127.0.0.1:34737/ (http://127.0.0.1:34737/:5)
```

`env=` / key 值 / `xl_launch_token` / `PDSH_DSH_LAUNCH_TOKEN` 四个 grep 全部归零，同时**正常日志仍在**（`PDSHEngine` 37 行、console 8 行）——「修好」必须同时满足这两条，把日志全删也能让 grep 归零。

## 15. Worker env 里的 key 是 placeholder（规范修正）

一个我自己犯过的错：曾把真 key 注入 `DEEPSEEK_API_KEY` 以让 demo 跑通。`gateway-security.md` §2 明确 **Worker 永不持有 key**（iOS 基线传 `phone-host-injects-mcp-key`，由 host 在网关注入）。

已改回：**三个状态下 `DEEPSEEK_API_KEY` 恒为 placeholder**，真正的状态在 `PDSH_MODEL_KEY_STATE`；真 key 只经 `ModelGatewayCredentialProvider`（origin + 协议路径限定、fail-closed）到网络边缘。

这个修正让 §13 的残余暴露从「真凭据」降到「launch token + 公网 base URL」。

## 16. 最根本的问题：页面结构没有契约，26 个页面各自发明

原始方案的决策输入写着「**UI 界面与交互双端一致**（实现语言可换 Android 原生）」。这一条没有被机器强制，结果是两套 UI 方案。

实测（grep，不是印象）：

| 页面 | iOS 基线 | Android 当前 |
|---|---|---|
| `SessionsPage` | **8 个 Section**：已归档 / 下一轮 / 当前步骤 / 新建会话 / 新建工作文件夹 / N 个会话 … | 扁平列表，文案只有 `new conversation` / `no sessions` / `unnamed` |
| `SettingsPage` | **27 个 Section**：内存 / 后台 / 命令 / 完全权限 / MCP 网络与密钥 / 允许列表 / 关于 … | 只有「平台差异（通知/电池/返回手势）」+ 5 个导航行 |

### 根因是规范，不是实现

`spec/ui/v1/README.md` §1 对每个页面只有**一行**职责：

```
| SessionsPage | 会话列表 | 抽屉「会话」 | push | must |
```

一行写「会话列表」，任何实现者都会做成扁平列表——而基线有三个分区加一个排队区。

而 `ui_check` 只检查「README 命名了每个 iOS `*Page` struct」——**命名对齐，结构完全不管**。所以 26 个页面各自发明了结构，全部门禁绿。

### 修法（本轮开工，未完成）

1. **机器化提取**基线结构成 `spec/ui/v1/pages/<page>.json`（sections / rows / actions / states，每项带 `file:line` 出处）
2. **双向强制**：Android 页面的 section/action 集合必须与契约一致，多、少都红；「平台被迫差异」必须引用 `spec/platform/whitelist.json` 的具体条目
3. **按契约重排**页面

**第 2 步是关键**——只做第 1、3 步，对齐一次之后还会漂。

### 为什么它比那 26 个没实现的写手势更严重

写手势是「功能没做」，这一条是「**做错了方向**」。前者补上就行，后者意味着已经写下的 26 个页面里有相当一部分要按基线重排——而那些页面每一个都有四态、有 token 对账、有测试，**全绿且全错**。

这是本次移植里唯一一处「检查器越完善，越掩盖了方向错误」的地方。

## 17. 真模型回合跑通（真 key，worker 侧无 key）

这是「§2 Worker 永不持有 key」在**真上游**上第一次成立的证据。

### 链路

```
worker --(DEEPSEEK_BASE_URL = http://127.0.0.1:<loopback>)--> 宿主模型代理
        --(Authorization: Bearer <真 key>，由宿主在边缘注入)--> https://api.deepseek.com/anthropic
```

`DEEPSEEK_API_KEY` 在 worker env 里**恒为 `phone-host-injects-mcp-key` 占位符**，三个状态（configured/absent/invalid）都是。真 key 只在 App 内存与代理的注入路径里。

### 回合

```
launch: --es pdsh.deepseek.baseUrl https://api.deepseek.com/anthropic
APP_TURN_OK kinds=turn_started,user_message×4,assistant_message,usage,
                 tool_call,tool_result,tool_call,tool_result,
                 assistant_message,usage,turn_ended reason=completed
```

模型输出（设备 WAL 的前 120 字）：

> `phone info` ran successfully (exit 0) and printed device details as JSON: | Field | Value | |---|---| | Model | `sdk_g…

### 三个断言

| 断言 | 证据 |
|---|---|
| key 不进日志 | `grep -oE "sk-[A-Za-z0-9_-]{16,}"` → app tags **0**、全 logcat **0**；`authorization\|bearer` **0**；placeholder **0** |
| worker 的 base 是 loopback | `start: model edge mounted: DEEPSEEK_BASE_URL=http://127.0.0.1:43543`；`grep -c api.deepseek.com` → **0** |
| 上游收到宿主注入的 Authorization | 经本地中继转发真上游，**6/6** 请求：`RELAY path=/anthropic/v1/messages status=200 auth_header=present auth_len=35 x_api_key=absent` |

**最有力的一条是反证**：把占位符直接当 key 打真上游 → `HTTP 401`。所以「上游 200」证明的是**注入的是宿主 key**，不是占位符。

### 顺带修掉的一个真实阻塞点

`LoopbackAssetResponder` 的 `shouldInterceptRequest` 原来把 `POST /v1/messages` 拦成 **405**（`bundle: POST /v1/messages -> 405`），Ktor 的模型路由永远收不到请求。

**这个 bug 不会让任何测试变红**——测试直接打 Ktor，不经过 WebView 的 intercept。只有真机真 WebView 才能暴露它。

修法：只拦 GET/HEAD 且 bundle 里确实存在该文件，其余放行给 origin。

### 一个必须记的陷阱

`https://api.deepseek.com` 对 **Messages** 是 **404**；该 provider 的 Messages base 是 `https://api.deepseek.com/anthropic`。第一次用纯 origin 失败时，是 **bogus key 的 401 掩盖了 404**——错误码指向了错误的原因。

宿主**不自动补齐**路径前缀（会把某个 provider 的约定硬编码进去），改为启动时 WARN + 在 `ProbeLaunchConfig` 的 KDoc 写明「launch 值必须是该 provider 的 Messages base」。

### 脚本夹具不接触真凭据

`pdsh.model.proxy`（默认 `true`）为 `false` 时不挂模型代理。`run-app-turn.sh` 显式传 `false`——因为脚本上游是**测试夹具**，挂上代理就会把设备上的真 key 注入它。

验证：加了开关后脚本 **12/12 断言仍全过**，且 logcat 里没有 `model edge mounted`。

## 18. UI 结构对齐：一条判据 + 一个可核对的数

### 判据（这一轮出现过四次「gate 与正确实现相反」后定下的）

> **gate 看不见一个正确的实现时，修 gate。**
> **实现把信息藏起来时，修实现。**
> 区别是：**信息是否在源码里显式可见。**

| 情况 | 信息在哪 | 修哪边 | 实例 |
|---|---|---|---|
| `Button { Text("Run all probes") }` | 源码里明写 | **gate** | checker 原先只认 `SessionTextAction` |
| `SettingsRowItem(row.title)` | 运行时才知道 | **实现** | 11 个设置动作被数据驱动藏起来 |
| 页面级 token 被要求标 `unverified` | 源码里能看出用了哪个 token | **gate** | 规则收窄为「只查借用的」 |

判据写进了 `page_structure_check.py` 的模块 KDoc 与 `spec/ui/v1/README.md` §1。**它比多识别几种控件重要**——以后每次冲突都靠它决定往哪边修。

### 可核对的数

`page_structure_check.py --strict`：契约（从 iOS 源码抽取，每项带 `file:line` 与 `anchor`）与 Android 页面的**分区/动作集合差**。

- 起点：224（口径扩到 24 契约 + 26 个 Android 页面全覆盖）
- 当前：**174**（`missing-action 55 / extra-action 40 / missing-section 31 / extra-section 14 / unresolved-action 21 / unresolved-section 9 / orphan-presentation 5`）

**这个数不能用来自我表扬**：N1 在隔离测量里把「识别器改进」的效果（−3）与「Android 页面同时被改」的效果分开了，并明确说 224→173 不能全记在 gate 头上。要求别人报数时分开归因，自己也得这么做。

`orphan-presentation 5` 是**基线自己的死 UI**（`ChatPage.swift:292`、`SessionsPage.swift:342/349/350/381`），机器证实了 `spec/ui/v1/README.md` §1.1 早前的人工登记。这 5 条不该去实现。

### 维护动作（必须记住）

`--baseline` 是 ratchet：**新增差异红，已修好的条目也红**（`stale`）。所以每轮对齐落地后必须跑一次 `--write-baseline` 收敛。忘了的后果是「修好的东西反而把 CI 弄红」——这是机制的正确行为，但对不熟悉的人像个 bug。

### §17 补：三条更硬的证据

**1. 脚本夹具从未接触真凭据。** 用 `pdsh.model.proxy=false` 跑 `run-app-turn.sh`：12/12 断言全过，引擎日志是

```
model edge disabled by launch (pdsh.model.proxy=false); the Worker env keeps its base URL
```

没有任何 `model edge mounted` 行。再换一个会记录请求头的假上游，它收到的是：

```
MODEL_REQ path=/v1/messages auth_header=absent auth_len=0
          x_api_key=present placeholder=phone-host-injects-mcp-key
```

**只有占位符，没有 Authorization。** 这比「日志里没有 key」硬——它证明的是夹具**收到的**东西。

**2. 挂代理时真 base 根本不进 env。** `workerEnvironment(modelProxyMounted = true)` 会**整条省略** `DEEPSEEK_BASE_URL`；真 base 只留在组合根与 credential provider，loopback origin 由 engine 在 `launchUrl()` 填。多一道防线，少一处泄漏面。

**3. 裸 origin 的启动告警。** 挂载时若 base 无路径前缀：

```
W PDSHEngine: start: the mounted model base URL is a bare origin with no path prefix;
  a provider whose Messages API lives below a prefix (for example /anthropic) will answer 404 there
  — pass the provider's Messages base, not its origin
```

不自动补前缀（那会把某个 provider 的约定硬编码进宿主），改为一句话告警。

### 真回合的完整证据（可复核）

```
launch: --es pdsh.deepseek.baseUrl https://api.deepseek.com/anthropic
        --es pdsh.prompt "Run phone info and tell me what it says."
→ APP_TURN_OK kinds=turn_started,user_message×4,assistant_message,usage,
                       tool_call,tool_result,assistant_message,usage,turn_ended reason=completed
```

模型输出（worker 的 `session.v4.jsonl`，前 200 字）：

> `phone info` returned: `{"model": "sdk_gphone64_arm64", "manufacturer": "Google", "device": "emu64a", "sdk": 35, "release": "15", "abis": ["arm64-v8a"], "display": {"densit…` （结尾：…with a 1080×2400 display at 420 dpi (density 2.625).）

五条 grep，全部 0：`sk-[A-Za-z0-9_-]{16,}` / `api.deepseek.com` / `authorization|bearer ` / `phone-host-injects-mcp-key`；`DEEPSEEK_BASE_URL` 是 `http://127.0.0.1:40053`。

上游经本地中继观测 **3/3（另两次 6/6、9/9）**：`RELAY path=/anthropic/v1/messages status=200 auth_header=present auth_len=35 x_api_key=absent`。

**反证**：直接拿占位符当 key 打真上游 → `HTTP 401`。所以上游 200 证明注入的是 35 字符的宿主 key，不是 28 字符的占位符。

## 19. 已知不可达（不是缺陷，是生产链缺数据）

三条功能在页面侧完整实现、且有测试，但**永远不会出现**，因为数据在更上游就没了。它们记录在此，不当作已完成。

| 功能 | 为什么不可达 | 解除条件 |
|---|---|---|
| 入站消息附件（`ChatRow.User.attachments`） | `spec/host/v1` 的 `user_message` 只有 `session_id/seq/time_ms/kind/text/source`（`additionalProperties: false`），**没有附件成员**；Android 在 host 事件层就丢弃了附件数据 | 契约补齐后，ui-state 节点的 `attachments` 做成可选且与 `ChatAttachment` 同形（`name`/`mimeType`/`image`/可选 `path`） |
| Android 的 assistant 图片块行 | 无对应 `ChatRow` kind | 同上 |
| `inbox_spliced` 里的 user 消息 | **基线自己也不产这一行**（`event-kinds.md` §1 标 `—`，iOS 投影器同样跳过） | 不需要解除 |

**加一个永远为空的字段是在类型系统里说谎。** 所以宁可让成员不存在，也不加一个恒为 `emptyList()` 的 `attachments` —— 那会让下一个人以为「附件已经在传输了，只是没渲染」，然后去查渲染层。

### 一个反向的诚实点：`unknown` 不是「注入块」

`source` 在 `spec/host/v1` 里是 **required** 成员，所以生产链永远有 source。缺 source 只出现在 golden 夹具与适配器容错路径。若把 `unknown` 当作注入块，**5 个 golden 的主 prompt 全都会变成「上下文」**——这本身就证明 `unknown` 是缺省标记而非生产者声明。

## 20. 结构契约覆盖不到的页面（P1 车道的可达性审计）

iOS 基线里 **24 个契约页只有 4 页在 iOS 上真能走到**：`settings` / `chat` / `sessions` / `files`。其余：

| 页面 | 不可达原因 |
|---|---|
| `background` / `probes` / `task-screen` / `memory` | `DevelopmentToolsPage` 与 `developerGroup` 是死代码，`SettingsPage.body` 只挂 `mainGroup`/`toolsGroup`/`aboutGroup` |
| `session-activity` | `showActivity` 只接了 `.sheet`，**没有任何地方置 true**（`spec/ui/v1/README.md` §1 早已登记「基线不可达」） |
| `daily-brief` | 全仓没有 `DailyBriefPage(` 调用点 |

**这不改变「要对齐」的结论，但改变了口径**：这 20 页的契约来源是「**iOS 代码里写的页面**」，不是「**iOS 用户看到的页面**」。回执里必须分开记——否则读的人会以为我们验证了 iOS 用户可见行为。

### 顺带发现：iOS 基线在 HEAD 上不能编译

```
examples/probe-app/ProbeKit/Office/OfficePresenter.swift:84:77:
error: type 'ChatHostConfiguration' has no member 'defaultOfficeInteractionTimeout'
```

`ChatHostConfiguration.swift` 在 2026-10-31 10:33 被改过，那个常量没有定义。`xcodebuild -scheme PhoneDSHProbe build` → **BUILD FAILED**，无 `.app` 产出。这是基线自身的损坏，应报给基线 owner。

## 21. 规范与基线不一致：三处，方向相反

对齐 UI 时发现 `spec/ui/v1/README.md` §1 与 iOS 基线有三处不一致。

| # | 位置 | 不一致 | 该怎么做 |
|---|---|---|---|
| 1 | `SettingsPage.swift:322` | 「密钥只保存在本机…」在死 `modelSection` 里 | **不抄**（基线有，从不渲染） |
| 2 | `SettingsPage.swift:458` | 「会话记录和文件都保存在这台手机上。」在死 `aboutSection` 里 | **不抄** |
| 3 | `SettingsPage.swift:287` | **§1 要求设置里有「运行时详情」行，而这一行只存在于死 `advancedSection`，`body` 从不渲染** | **照 §1 做**（我们该有） |

前两处是「基线有、不渲染」，第三处是「**§1 要求、基线不渲染**」——方向相反，但都指向同一件事：

> **基线里有死代码，而 §1 是照着「代码里有什么」写的，不是照着「渲染出什么」写的。**

### 判据（以后遇到 §1 与基线冲突）

| 情况 | 依据 |
|---|---|
| §1 要求、基线不渲染 | **照 §1 做**，并在契约里同时记录两处出处（`swift:line` + `README.md:line`） |
| 基线渲染、§1 没写 | **照基线做**，让 §1 补上或明确标为死代码 |
| 两边都要求但文案不同 | **页面名用 §1，行文案用基线**（`EgressAllowListPage` 的页面名是「出网白名单」，设置行文案是「网络访问」，两者本来就不同名） |

第三条是我犯过的一次错：我把 §1 的「职责」列（页面名）当成了「入口」列的行文案，要求把设置行改成页面名。**§1 的「入口」列只写「设置行」，没给行文案**——所以行文案该照基线。

## 22. 无密钥的干净安装也能跑 acceptance（12/12）

对 PR 门禁而言这条是前提：**验收脚本不能要求凭据**。

```
adb uninstall com.phonedsh.probe      → KeyStore 里的 key 随应用数据清除
./gradlew :app:installDebug
bash android/tools/run-app-turn.sh    → 12/12 PASS
```

脚本用 `--ez pdsh.model.proxy false` 关掉模型边缘，worker 的 `DEEPSEEK_BASE_URL` 保持指向脚本上游。所以：

- **有真 key**：走宿主模型边缘，真上游，worker 无 key（§17）
- **无 key**：走脚本上游，12/12 断言通过（本节）
- **测试夹具永远不接触真凭据**（§17 补）

三条路径互不依赖凭据的存在。

## 23. UI 结构门禁的最终形态

### 数字与口径

`page_structure_check.py --strict`：**147 条**（起点 224；中途因 gate 变严涨到 188，再收敛到 147）。

**这个数在过程中涨过两次，每次都能解释：**

| 阶段 | 数量 | 变化原因 |
|---|---|---|
| 初版 | 224 | 24 契约 + 26 个 Android 页面全覆盖 |
| 修 gate（认标准控件、presentation 内动作、无标题组判据） | 188 | **之前看不见的对比面**进来了（+15） |
| 修契约（误报作用域、§1 附加项归位） | **147** | −26：第一版 `spec-baseline-mismatch` 的误报 + chat 同期对齐 |

**涨不等于退步。** 一个检查器发现更多真实差异，是它变好了。

### 三套「不是差异」的机制

| 机制 | 装什么 | 约束 |
|---|---|---|
| `_whitelist.json` | 平台被迫差异（1 条：`settings.platform-appendix`） | 每条必须有 `platformRef` 指向 `spec/platform/whitelist.json` 的真实条目 |
| `_unrecognized.json` | 静态不可比对的项（11 条） | 必须匹配真实 finding、`reviewBy` 未过期，否则 checker 报错 |
| `_spec-required.json` | **§1 要求、但基线不渲染的条目**（1 条：`运行时详情` 设置行） | 由 extractor 合并进契约，可重复生成；`baselineReachable: false` |
| `deadUi: true` | 基线自己的死 UI（5 个 presentation） | 必须 `triggered: false` 且有 `deadUiEvidence` |

**三种归类的共同点：不是「忽略」，是「归类并打印」。** 报告里能看见每一条，只是不计入 divergence。

### `spec-baseline-mismatch`：把「规范与基线不一致」变成可见事实

判据是**入口短语 → 来源宿主**：

| §1 的入口措辞 | 来源宿主 |
|---|---|
| `设置行` / `设置 →` | SettingsPage |
| `抽屉 …` | **app shell（`NativeShell.swift`）** |
| `页头 …` / `对话里 …` | ChatPage |
| `工作面板 …` | NativeWorkbenchPage |

第一版在会话页里找抽屉的入口，报了 4 条误报。修好后全量 **1 条，且 `[acknowledged]`**。

`[acknowledged]` 与 `[open]` 分开：带 `specRef` 的列出但不计红，不带的计入——**所以「已登记的不一致」和「没处理的不一致」在报告里分得开。**

### 当前分布

归零 **3/24**（`files`、`memory`、`settings`）。剩余 147 条里最集中的 8 页占 111 条（76%）：

```
model-provider-settings 19 │ native-configuration 19 │ web-search-settings 17
native-automation 15 │ session-activity 12 │ mcp-editor 11 │ runtime-details 10 │ mcp-settings 8
```

### 一个必须分清的记法

`missing-action 56` 里有相当一部分**不是「做成了两套 UI」，是「功能没做」**——基线有编辑器，Android 只有只读视图（egress 的 6 个、model-provider 的 5 个、native-automation 的 3 个写动作）。

| 性质 | 修法 | 记法 |
|---|---|---|
| 做成了两套 UI | 按基线重排 | 「UI 对齐进行中」 |
| 功能没做 | 补实现 | 「未实现」 |

**把「没做」记成「没对齐」，会让读的人以为我们做过又做错了。**

### §22 补：无密钥验收在全新 userdata 的 AVD 上复现

前一条车道的验证用的是「卸载重装」（KeyStore 清空，但 userdata 有残留）。导航车道在一台**全新 userdata 的私有 AVD** 上独立复现：

```
12/12 PASS
model edge disabled by launch = 1
model edge mounted = 0
上游照常收到 3 个 MODEL_REQ
```

**这是 CI 能跑 acceptance 的决定性证据**——否则「验收需要凭据」会让 CI 要么跳过、要么注入凭据。

### 一条三值原则：`UNKNOWN` 不等于 `NO`

五页的 `writable: FactState` 用 `enabled = writable != NO`，而不是 `== YES`。

理由：**宿主没报可写性，不等于它报了只读。** 在 `UNKNOWN` 上禁用，是断言一件我们不知道的事。

这和页面渲染 `未知` 而不是 `0` 是同一条规则：**`FactState` 是三值的，把它折成二值就是在三值类型上做二值假设。**

宿主显式传 `NO`（6 处），所以实际行为正确；`UNKNOWN` 只在「有别的宿主」这一假设下才可能不同。

### 一条测试纪律：断言 `enabled` 属性，不是颜色

五页禁用态用 `uiautomator dump` 断言 `enabled='false'`，而不是截图比对灰色或 `alpha`。

**后者可以被样式骗过，前者是系统事实。**

## 24. 更正：iOS 用户可达的是 17 页，不是 4 页

§20 写的「24 个契约页只有 4 页在 iOS 上可达」是**错的**。那是 P1 车道在**还不会自动点击时**的初判（当时只有 chat/sessions/files/settings 能靠 `-uiPreview` 到达）。

用固定机型 + `simctl launch -uiPreview` 重跑后的真实结果：

| 类别 | 数量 | 页面 |
|---|---:|---|
| **用户可达** | **17** | chat、sessions、files、settings、model-provider、web-search、mcp-settings、mcp-editor、native-configuration、native-automation、egress、runtime-details、workspace-folders、pdsh-shell、native-workbench（条件可达）、export、web-surface |
| 仅预览可达 | 1 | settings-about（产品内「关于」是 Settings 的一个 group） |
| **不可达** | **6** | background、probes、task-screen、memory（唯一父级 `DevelopmentToolsPage` 从未挂进 `body`）、session-activity（`showActivity` 从未置 true）、daily-brief（0 个调用点） |

**结论反转**：那 20 页不是「代码级对齐」，其中 13 页 iOS 用户真能看到。**对齐它们有用户可见价值。**

## 25. 结构门禁看不见布局——这是它的已知边界

`page_structure_check.py` 比的是**分区与动作的集合**。它看不见：

- 字号（iOS 输入 17pt vs Android ≈12–14sp）
- 行高（iOS 44pt 行 vs Android 50–57dp）
- 控件形态（iOS 两行 94pt 卡片 vs Android 48dp 单行胶囊）
- 圆角、描边、阴影、间距

**这不是缺陷，是范围**——但必须说清，否则「146 条差异」会被误读成「还差 146 处 UI 问题」。

真实情况是：**集合差 146 处，布局差异另有一批，后者由 iOS 截图对照发现。**

### 输入坞的实测差异（P1 量出来的）

| 项 | iOS | Android |
|---|---|---|
| 形态 | 两行卡片，高 **93.7pt**（收起）/393.7pt（展开） | 单行胶囊，**48dp** |
| 圆角 | **22pt** | 胶囊（半高） |
| 控件行 | 高 32pt：`+`(28pt) / 权限盾 17pt / 模型菜单 15–17pt / 发送 34pt | 只有发送圆钮 |
| 输入字号 | **17pt**，行距 24pt | ≈12–14sp（CJK 步进 ≈11.9dp/字符） |
| 占位色 | `#ACB1B7` | — |
| 发送钮 | 34pt 圆，禁用 `#D7E0FF`，`arrow.up` 15pt bold 白 | — |

**这是「两套 UI」里最明显的一处**，而结构门禁完全看不见它。

### 另两处

| 项 | iOS | Android |
|---|---|---|
| Chat 顶栏 | 居中 17pt 标题 + 侧栏图标 + 绿点**和「运行中」文字** + 蓝省略号 | 汉堡 + 左对齐 ~22sp + 只有圆点 |
| 列表节奏 | 44pt 行 / 17pt 标签 / 13pt 灰组头 / 0.33pt `#DDDCE2` 分隔 | 50–57dp 行 / ~16sp 带 chevron 组头 |

## 26. iOS 基线在 HEAD 上不能编译（可引用）

```
$ xcodebuild -scheme PhoneDSHProbe -sdk iphonesimulator build
examples/probe-app/ProbeKit/Office/OfficePresenter.swift:84:77:
error: type 'ChatHostConfiguration' has no member 'defaultOfficeInteractionTimeout'
** BUILD FAILED **
```

`ChatHostConfiguration.swift` 于 2026-10-31 10:33 删除了该常量，全仓无第二处定义。**全新的 DerivedData 同样失败**——不是缓存问题。

截图用 `$TMPDIR` 临时副本补了一个 `static let defaultOfficeInteractionTimeout: TimeInterval = 60`（只约束 Office picker 的 deadline，不参与任何被截页面渲染），UI 源码与 HEAD 逐字节相同，`INDEX.md` 顶部有显著声明。**没有用旧 DerivedData 的二进制冒充 HEAD。**

这两条（基线编译损坏 + 截图用的临时补丁）都应报给基线 owner。

### P1 提出的七个问题：裁定

| # | 问题 | 裁定 |
|---|---|---|
| 1 | `defaultOfficeInteractionTimeout` 修什么值、归谁 | **不修**。`examples/**` 是基线、只读；这是基线自身的损坏，报给 owner。若要复现截图，按 §26 用 `$TMPDIR` 副本补值并声明 |
| 2 | 四个探针页恢复 Settings 入口还是降级契约 | **既不恢复也不降级**。契约保持（它们是真功能、§1 标了 `must`/`later`），回执标「基线侧不可达」，优先级排在那 17 页之后。**不要去基线里加入口**——那是造一个不存在的产品 |
| 3 | `chat.official` 空 transcript | **基线的预览路由缺陷**（2.5/6/12 s 均空）。不属本移植范围，记录即可 |
| 4 | 定时任务页 host-off 打英文 `ProbeKit.ProbeHostError error 3` | **不抄**。我们把 host 失败渲染成中文 fail-loud 行，且保留「重试」。原始错误对象进日志，不进 UI |
| 5 | Android 截图基线是旧结构，视觉对齐是否等结构对齐后 | **是**。现有 11 张 Android 基线拍于页面重写之前，**已失效**；结构定稿后统一重生 |
| 6 | iOS 设置页 Toggle 行只有 34pt、分隔线从开关下缘穿过 | **不抄这个瑕疵**。镜像布局但修明显缺陷，并在 §27 记录 |
| 7 | 无 idb，交互态无法点击 | **接受「只有静态预览态」的基线口径**。Menu/Picker/Switch/确认对话框的展开态记为「未测量」，不冒充 |

## 27. 三条「不抄」的基线瑕疵

对齐不等于逐像素复制。以下三条是基线的缺陷，镜像它们等于把 bug 移植过来：

| # | 瑕疵 | 我们的做法 |
|---|---|---|
| 1 | 设置页 Toggle 行高 34pt，分隔线从开关下缘穿过 | 行高按 44pt 统一，分隔线在行边界——**修，不抄** |
| 2 | 定时任务页 host 失败时把 `ProbeKit.ProbeHostError error 3` 原样上屏 | 渲染中文 fail-loud 行 + 重试；原始错误进日志 |
| 3 | `完全权限` 那个 section 的标题是 Swift 的字符串比较操作数 | 契约标 `suppressed`，不给 Android 造假字面量（§23） |

**判据**：镜像**结构、文案、交互语义**；不镜像**明显的实现瑕疵**。每一处不抄都要在回执里列出，否则看起来像漏做。

## 28. Android 截图基线已失效（待重生）

`android/lib/src/test/resources/screenshots/` 里的 11 张 Android 基线拍于**页面重写之前**（`page-chat` / `page-sessions` / `page-settings` 都是旧结构）。iOS 截图对照时 P1 指出：

> Android 的 `page-settings` / `page-sessions` 基线看起来是另一套（或旧版）页面

**这是预期的**，不是缺陷——基线的作用是「防回归」，而结构正在变。处理：

1. 等结构对齐落地（`--strict` 收敛后）
2. 重跑 `android/tools/screenshot-capture.sh` 重生基线
3. 重生的基线与旧基线**必然大不同**，差异本身就是这一轮结构改动的证据

**在此之前，不要用 Android 截图基线判断「视觉是否对齐」**——它拍的是旧结构。

## 29. 门禁造成的组件冗余：五种形态

这一轮最意外的成本来源。检查器的**识别器只认很窄的源码形状**，于是页面代码被迫长出双胞胎或绕开标准控件。

| # | 形态 | 门禁的窄判据 | 页面被迫做的 | 修法 |
|---|---|---|---|---|
| 1 | `PendingFoldRow` vs `FoldedPendingRow` | wrapper 索引只扫 `ui/page/*.kt` | 在页面里复制一份组件 | 索引扩到 `ui/**`（已修） |
| 2 | `HeaderMenuAction` vs `HeaderAction` | wrapper 要求**首参名叫 `label`** | 写一对逐行重复的组件 | 契约补抽屉动作 `打开会话列表`（待修） |
| 3 | 自绘 `Row` 替掉 Material `DropdownMenuItem` | `DropdownMenuItem(text = { Text(数据) })` 一律 `unresolved` | **绕开标准控件** | 把「动态首文字行不算动作」的判据也用到 `DropdownMenuItem`（待修） |
| 4 | 同一菜单两种分组头画法 | 动态 section 标题只会是 `unresolved-section` | 一半用 `*SectionLabel`，一半降级成禁用菜单项 | 动态菜单分组头按 `suppressed` 处理（待修） |
| 5 | `%d 项需要处理` 被读成具名动作 | `resolve_kotlin_expr` 把 `format(...)` 当字面量 | 无（纯误判） | 带 printf 占位符的标签是**模板**，不参与比较（待修） |

### 判据

> **凡是「把判据放宽到语义等价」能解决的，都不该让页面复制组件或绕开标准控件。**

第 3 条尤其值得记：为了让门禁看懂，页面**主动放弃了 Material 标准组件**——这正是我一直在批评的反向改动。

## 30. 并发环境下的验证方法（操作纪律）

多条车道同时跑 Gradle 会互相破坏 `android/lib/build/test-results/**/binary/output.bin.idx`。实测症状：

- `NoSuchFileException: output.bin.idx`（连续 2 次）
- `ClassNotFoundException: ...PageTest`（1 次）
- `Could not write XML test results for ...BubbleSurfaceTest`
- `test-count.sh` 报 `ParseError: no element found` 或 `TOTAL 0 tests`

**这些都不是代码问题，是并发写同一个 build 目录。** 应对方法（前一条车道验证有效）：

```bash
rsync -a --exclude build --exclude .gradle android/ /tmp/iso/android/
ln -s <repo>/spec <repo>/examples <repo>/shell <repo>/README.md /tmp/iso/
```

在隔离副本里跑测试与 verify 脚本，得到的数字才可引用。**共享树里的并发红不能当证据。**

## 31. 三个可空字段：从「类型说谎」改成「类型诚实」

契约与宿主模型把三个字段声明为非空，于是宿主只能传 `emptyList()` / `""`——而那是**一个事实陈述**，宿主其实不知道。

| 字段 | 改成 | `null` 的含义 | `emptyList()` / `""` 的含义 |
|---|---|---|---|
| `SessionListing.title` | `String?` | 宿主没有标题存储 → 行回退到「新会话 / 新会话 N」 | 宿主报了标题，且是空的 |
| `pinnedSessionIDs` | `List<String>?` | 宿主没有 pin 存储 → 保持自然顺序，**不声称「没有置顶」** | 报了，且没有置顶 |
| `workspaceOrder` | `List<String>?` | 同上 | 同上 |

**这是同一条规则的第四次出现**（前三次：`UNKNOWN ≠ NO`、`未知 ≠ 0`、`FactState` 三值）。

### 改动是「源码兼容」的，所以风险低

42 处测试构造 `SessionListing(title = "…")` 全部不用改（`String` 可赋给 `String?`）；`from(pinnedSessionIDs = listOf(…))` 同理。

真正要改的只有：
1. `sessionTitle(raw: String?)` —— `raw.orEmpty().trim()`，空与缺省走同一条 untitled 路径
2. 三个 `pinnedFirst(...)` / `orderWorkspaces(...)` 的调用点加 `.orEmpty()`
3. 宿主从 `emptyList()` 改成 `null`（因为**这才是它实际知道的状态**）

`:lib` 473 tests / 0 failing 未变。

### 一个顺手接上的空洞

`HostSessionsScreen` 之前**没有传 `onRefresh`**，所以 `PullToRefreshBox` 的下拉手势是 **no-op**——一个看起来能用、实际什么都没做的控件。

修法是接上宿主自己的一次扫描，并把「扫描进行中」作为一个事实投影出来：

```kotlin
HostSessionSnapshot.scanInFlight   // true while a journal scan runs
SessionsPage(
    state = screenState.copy(refreshInFlight = sessionSnapshot.scanInFlight),
    onRefresh = { engine.refreshSessions() },
    …
)
```

**spinner 反映宿主真的在跑的那次扫描，不是本地计时器。**

## 32. 用模拟器里的 flash 当子 Agent 做联调（首次真正联调）

前一次真模型回合是**单发**：一句 prompt、跑完、读结果。这一节是**联调**：把装在模拟器里的 `deepseek-flash` 当成有工具访问权的子 Agent，给它调查任务，读它的回答，再去核对。

### 方法

一个探针脚本（`/tmp/joint-probe.sh`，不入库）：launch（真 base + prompt）→ 等 `APP_WORKER_READY` → `uiautomator dump` 找到「跑一轮」→ tap → 等 `APP_TURN_OK` → 从 worker journal 读最后一条 `assistant/message`。

两个坑（都记下来，下一个人会撞）：
1. **`--es pdsh.prompt` 里的空格会被 device shell 切开**，整句变成 Activity 名（`Error: Activity class {/proc/version} does not exist`）。必须整条 `am start` 用双引号包住。
2. **tap 目标必须是精确匹配**。页面上有一句说明 `点「跑一轮」经宿主 /api 车道发起 session/prompt。` 也含「跑一轮」，按子串匹配会点到标题（445,1670），**tap 静默无效、没有任何报错**。正确按钮在 (540,2197)。

### 它找到的真 bug：能力撒谎

`capabilities.json` 声明 **92 个命令，含 `python3` / `python` / `jq`**。实测：

| 命令 | 结果 |
|---|---|
| `python3 -c 'print(1+1)'` | **exit 1** |
| `jq -n '1+1'` | **exit 1** |
| `python3`（cwd `/`） | **exit 1** |
| `python3` 从 stdin 读 | **exit 1** |
| `jq --version` | **exit 1** |

错误全文（100% 复现，与 cwd、参数、stdin 无关）：

```
python3: EACCES: session-internal state under /dsh/home/sessions is not readable
         from an execution surface; read it through the session API or copy
         what you need into /dsh/workspace first (/dsh/home/sessions)
pdsh-shell: exit=1 program=python3 reason=backend-failed
```

### 损伤范围（用同一个子 Agent 量出来的）

| 能用 | 不能用 |
|---|---|
| `cat` `sed` `grep` `awk` `base64` `find` `git` `sort` `tar` | **`python3`** **`jq`** |

所以只挂在**两个 WASI 解释器后端**上，不是整个 shell。

### 根因：guard 是对的，应用点错了

拦截来自我们自己的代码——`plugins/wasi-toolbox/src/vfs-namespace.ts:288` 的 `assertExecReadable`，抛出 `execReadDeniedMessage`（同文件 :110）。

而 `spec/v1/channel.md:263` 写的是：

> `/dsh/home/{sessions,storages,tool-journal}/**` is DSH-internal: execution surfaces (`bash`, `python3`, `git`) receive `EACCES` with a remediation line **and never see the bytes**.

**契约说的是「surface 去读那些路径时」给它 EACCES。** 而 `python3 -c 'print(1+1)'` 根本没有去读那些路径——它**在跑任何用户代码之前就死了**。

也就是说：拦截点在 **WASI 引擎初始化/preopen 阶段**，而不是 guest 的**实际访问**点。`vfs-client.ts:55-56` 自己的注释就是线索：

> a missing preopen is an expected answer, not a protocol failure, so the preopen probe uses this form

**探针本来就允许失败，但这条路径把失败变成了致命。**

### 这不是已知问题

`docs/`、`android/README.md`、`spec/` 里没有任何一处登记 `python3`/`jq` 不可用。**是联调新发现的。**

### 顺带两条小发现

- `HOSTTYPE=x86_64` / `MACHTYPE=x86_64-pc-linux-gnu`，而设备是 **arm64**——shell env 里的一个假值。
- `curl --version` → `unsupported option --version`（自建 curl 的精简选项集），属能力描述与实际不符的同一族。

### 一个正面的观察

第一个探针我问它「读 `/proc/version` 报内核版本」。`/proc` 在 WASI 沙箱里不存在，它连试 6 次工具之后回答：

> **结论：无法给出。** 用工具读取 `/proc/version` 时失败，因为当前执行环境（WASI 沙箱）中不存在 `/proc` 文件系统…因此，这台设备的内核版本和 Android 版本都无从获取，**我不会编造数值**。

**它没有编。** 这恰好验证了「未知必须显示为未知」这条规则在模型侧也成立——前提是工具如实返回失败，而不是伪造一个看起来合理的值。

## 33. 联调：把模拟器里的 flash 当子 Agent（续）——一个真 bug 的修复与一个更深的坑

### 已修复：快照遍历遇到策略拒绝就整体失败

`plugins/wasi-toolbox/src/vfs-snapshot.ts` 的 `walk()` 只容忍 `ENOENT`：

```ts
if (path === root) missing.push(path)
else if ((error as { code?: unknown }).code !== 'ENOENT') throw error   // EACCES 被重新抛出
```

而执行面策略**故意**对 `/dsh/home/{sessions,storages,tool-journal}` 返回 `EACCES`（`spec/v1/channel.md` §VFS 明文）。两者相加：遍历到 `/dsh/home/sessions` 时整个快照构建失败。

**这是两个不同的东西被当成同一个**：

| 情形 | 含义 | 正确行为 |
|---|---|---|
| 截断（字节/条目上限） | 访客会看到**部分**视野 | **fail loud**（头注释本来就这么写的） |
| 被策略拒绝 | 访客**本来就不该看到** | **跳过**，和 `ENOENT` 同等对待 |

修复：`isInvisibleToExec(code)` = `ENOENT || EACCES`，遍历跳过而不是抛出。

**回归测试**（`vfs-snapshot.test.ts`）：一个对 `/dsh/home/sessions` 抛 `EACCES` 的 backend，断言快照仍然成功、被拒子树不在视野里、`omitted > 0`（不隐藏跳过）。
**反向验证**：把修复退回 `code === 'ENOENT'`，该测试红（`not ok 8 - a denied internal root is omitted from the snapshot, never fatal`）；恢复后 8/8 绿，`wasi-toolbox` 274 个测试全过。

**现有测试为什么抓不到**：`seed()` 的树里从来没有 `sessions` 目录，而 `MemoryVfsBackend` 从不抛 `EACCES`。这个 bug 需要一个**会拒绝**的 backend 才能暴露，而只有真实的执行面策略会拒绝。

### 但这个修复不是 `python3` 失败的原因（如实记录）

部署后 `python3 -c 'print(1)'` 仍然失败，报文一字未变。继续追查发现**更深的问题**：Android 侧 worker 载荷由**三个分别构建的产物**组成，而它们不共享同一次构建。

| 产物 | 谁生成 | 大小 | 说明 |
|---|---|---|---|
| `image.tar.gz` | `plugins/scripts/pack-image.mjs` | ~25 MB | VFS 镜像（`node_modules/@phone-dsh/*/lib/**.js` 在里面） |
| `tool-worker-python.js` | `plugins/worker-entry/build.mjs` | ~189 KB | python 的 tool worker |
| `worker-entry.js` | `plugins/worker-entry/build.mjs` | ~3.78 MB | 主 worker（`shell-ext` 在这里派发 `python3`） |

**我前四轮「修复」全部只更新了 `image.tar.gz`**，而抛错的是 `worker-entry.js`——它一直是我没碰的那份。诊断标记 `[diag]` 在仓库里、在 `/tmp/we/` 里有，在设备解包出来的 `worker-entry.js` 里没有（`marker=0`），这就是证据。

**教训**：改一个插件，要问的不是「源文件改了吗」，而是「**设备上跑的那个字节流是哪一次构建出来的**」。这条和「同一个数字写两处」是同一族：**同一个能力有三份构建产物，改一份等于没改。**

### 部署管线的第二个坑：解包是粘的

`files/worker/tool-worker-python.js` 在 APK 里已经是新的（189478 B），但设备上解包出来的仍是旧的。「升级安装」不会重解包；只有**卸载重装**才会。

所以验证一条 worker 侧的改动，必须 `adb uninstall` + `install`，不能只 `install -r`。

### 当前阻塞

- `emulator-5554`：system_server 死亡（`Can't find service: activity`），`adb reboot` 挂住不返回。该实例上报废。
- `emulator-5556`：可用（API 33），但回合启动即 `APP_TURN_FAILED reason=session_create_unavailable`（`session/create attempt 179 not answered`），需要单独查。

在这两个设备恢复到可用状态之前，`python3` 根因**尚未定位**。已排除：快照遍历（已修但不是它）、guest 环境变量（`env` 里没有 sessions 路径）。

## 34. 联调报告：四轮、12 项发现（设备 emulator-5558，API 35，真 key）

方法：把装在模拟器里的 `deepseek-flash` 当成**有工具访问权的子 Agent**，给它调查任务，它用 bash 工具在设备上实测，把原始输出报回来；**每一条都由我独立复核**。

### 能用的（好消息）

| 检查 | 结果 |
|---|---|
| 凭据不进 guest 环境 | `env` 里只有 `DEEPSEEK_BASE_URL`（loopback）与 `XL_IDEMPOTENCY_KEY`，**没有 API key** |
| 凭据不进 guest 文件 | 对 `/dsh/home`、`/dsh/workspace` 做 `sk-` 扫描，命中项复核后是配置键名 `sk-user`，**不是凭据** |
| `/tmp` 与 `/dsh/tmp` 同一目录 | 写 `/tmp/_p1` 后 `/dsh/tmp/_p1` 可见 |
| 写 workspace / 写 home | 都成功 |
| 基础命令 | `rg` `tar` `base64` `md5sum` `diff` `sed` `awk` `find` `sort` `file` 全部 exit 0 |

**凭据隔离这一项是干净的**，这是最要紧的一项。

### 坏掉的（都是「声明了但跑不动」）

| # | 能力 | 实测 | 严重度 |
|---|---|---|---|
| 1 | **`python3`** | `EACCES … /dsh/home/sessions`，5 种调用方式全失败 | 高 |
| 2 | **`jq`** | 同一个 EACCES | 高 |
| 3 | **`phone <tool>`**（整个手机工具面） | `unsupported: the request is not supported by this in-process accelerator; nothing executed` | **高** |
| 4 | `gzip --version` | 压缩能用（`echo hi \| gzip` = 23 B），但 `--version` exit 2 | 低 |

第 3 条最严重：`capabilities.json` 把 `phone` 写成 `phone <tool> <json-object>` 并列出 20+ 个工具（`files.list`、`device.info` …），而按它自己的调用方式执行，得到的是「unsupported … **nothing executed**」。**这是整块手机原生能力面不可用。**

### 不一致（同一路径两种行为）

| 观察 | 说明 |
|---|---|
| `ls /dsh/home/sessions` → **ENOENT**（不存在） | 而 `python3` 在同一路径上报 **EACCES** |
| `ls -l /dsh/home` 列出 `sessions`/`storages`/`tool-journal`，但逐个 stat 全失败 | 名字可见、实体不可访问 |

同一个策略在两个入口给出了不同的错误码。契约（`channel.md` §VFS）只规定了一种答复（EACCES + remediation line）。

### 环境里的假值

| 值 | 实际 |
|---|---|
| `HOSTTYPE=x86_64`、`MACHTYPE=x86_64-pc-linux-gnu` | 设备是 **arm64** |
| `curl --version` | `unsupported option --version`（自建精简版） |
| `/proc` | 不存在（WASI 沙箱无该文件系统） |

### 方法论：子 Agent 的结论必须复核

它报告「`/dsh/home/cordis.patch.yml` 里匹配到 `sk-`」。我去查：该文件里 8 处都是 **`sk-user`**（配置键名），不是凭据。

**这是误报**，原因是它那条命令的 shell 引号被吞、正则退化成子串匹配。

如果直接采信，就会在回执里写一条「密钥泄漏」的假警报。**联调的价值不在于子 Agent 说了什么，而在于它给出的原始输出可以被复核。**

## 35. 基线冻结与暂停口径（2026-11-01 11:00）

**iOS 基线此刻正在被补齐 DSH 官方能力**（另一条工作线，收尾中）：09:00 之后有 **35 个 `.swift` 文件**被改动，其中 `ChatPage.swift` +899/−94，新增子 Agent 目录、任务列表、计划预览、折叠回合、队列编辑等。

### 对我们的影响：UI 对齐的参照物在动

| 后果 | 处置 |
|---|---|
| `spec/ui/v1/pages/*.json` 的锚点全部失效（`page_structure_check.py` 报 `stale page contracts`） | **不重新抽取**。现在抽会对着一个还在变的文件，抽完还要再抽一次 |
| 已归零的 6 页（settings / memory / files / sessions / egress / workspace-folders）是**对旧基线**归零的 | 基线定稿后重新度量，必要时重新对齐 |
| 结构门禁此刻是红的 | **这不是回归**。红的原因是度量对象变了，不是我们的代码退步 |

**规则**：在基线冻结之前，`page_structure_check.py --strict` 的数字**不作为进度指标**。谁引用那个数字，必须同时说明它对应哪一版基线。

### 我们不动的东西

- `examples/**`、`Sources/**` 一律只读，不 revoke 别人的改动（那是正在进行的工作）。
- 不跑 `extract_ios_pages.py` 重新生成契约。

### 这段时间做的工作：与 UI 无关的部分

UI 之外的三项产品级缺陷仍在推进（都不依赖 iOS 基线）：

| # | 缺陷 | 车道 |
|---|---|---|
| 1 | `phone <tool>` 整个手机工具面返回 `unsupported … nothing executed`，而 `capabilities.json` 声明 20+ 个工具 | P1 |
| 2 | `python3` / `jq` 100% 失败（`EACCES /dsh/home/sessions`），而能力清单声明它们可用 | P2 |
| 3 | 同一路径两种错误码（`ls` 得 ENOENT、`python3` 得 EACCES） | P2 一并处理 |

**这三项是「能用」层面的缺陷，和「长得像」无关。** 基线在动不影响它们。

## 36. P7 补齐的四项，以及一个架构偏差

### 36.1 16 KB 页对齐（P2a 项，原来只在设计文档里）

flag 放在 `shell/crates/pdsh-jni/build.rs`，**只在 `CARGO_CFG_TARGET_OS == "android"` 时** emit：

```
cargo:rustc-link-arg=-Wl,-z,max-page-size=16384
```

`llvm-readelf -lW` 实测 aarch64 与 x86_64 的**全部 3 个 PT_LOAD 段 `p_align = 0x4000`**。

两条机器检查进 `structure_check.py`：

| 检查 | 判据 |
|---|---|
| `android-16k-link-arg` | 读 `build.rs` 并**先剥 Rust 注释**（注释里写 flag 不算），断言 `max-page-size >= 16384`、必须是 `link-arg`、**必须有 android 目标门控**（防泄漏到 host/wasm） |
| `android-16k-artifact` | ELF 解析 aarch64 debug/release + x86_64 debug，无产物时**明确 SKIP 而非 PASS** |

配 6 个变异测试（删 flag / flag 只在注释里 / 4096 / 去掉门控 / 错位产物 / 对齐产物）。

### 36.2 WebView 内核探测（R4 风险项）

新增 `android/engine/.../WebViewKernel.kt`：

- **内核版本只从 UA 取**（`Chrome|Chromium|CriOS/NN`），**绝不解析 versionName**——华为 `com.huawei.webview` 的 versionName 是另一套编号，按它判必错
- 厂商轴 `HUAWEI/GOOGLE/AOSP/OTHER/UNKNOWN`
- **特性检测而不是版本判断**：`readable-stream-async-iteration`、`readable-stream-pipe-through`、`decompression-stream-gzip` 为必需；`symbol-dispose` 可选（worker 自带垫片）
- 四态：`UNSUPPORTED`（缺必需）/ `UNVERIFIED`（没测到，**绝不当作支持**）/ `DEGRADED`（特性齐但版本未知或 <99）/ `SUPPORTED`
- **诚实降级**：`UNSUPPORTED` → `failEngine(...)`；App 在 Failed 时**不再挂空白 WebView**，改渲染 `EngineUnavailableNotice`
- 每次 `onPageFinished`（含 renderer 重建后）重新探针

### 36.3 ingress 幂等与顺序（P6 项，原来**零实现**）

`spec/host/v1/README.md:250` 把「持久 ingress 队列」明确列为**契约之上（above this contract）**——所以此前没有任何实现，这次是**新增**，且**没有改 spec**（把方案故意留白的东西冻结成 wire 语义是错的）。

`IngressQueue.kt`：按 origin 的 seq 顺序、requestId 全局去重（**跨重启**）、失败留队首且 parked 重试、迟到旧 seq 拒为 `STALE_SEQUENCE`、同 seq 不同 id 拒为 `SEQUENCE_CONFLICT`、单 drainer。13 个测试覆盖重复投递（含重启后）、乱序 2,3,1、缺口不跳号、park 中途生效。

### 36.4 `runsWhileAppSuspended` 原来是不诚实的

默认值是硬编码 `true`。改法很讲究：

- `HarnessCapabilities.runsWhileAppSuspended` 默认 **`true → false`**（KDoc：**默认值不是证据**）
- 新增 `BackgroundExecutionFacts(backendOutlivesApp, foregroundServiceUsable, useridtGranted, notificationsGranted)` + `narrowedTo(facts)`——**只收窄不放宽**
- 原来那条 `assertTrue` 在 `HarnessSessionTest`，它断言的是**解码 golden 里的 wire 值**——解码器不该改写 wire，所以**保持 true** 并加注释：「不诚实的是构造默认值，不是解码」

这个区分很准：**同一个字段，构造侧的默认值该收窄，解码侧不该改写。**

## 37. 架构偏差：UI 消费的不是 `AgentHarness`

原方案 §9.3 写的是：

> Compose 对表规范实现（**UI 层与 SDK 解耦已由架构保证：UI 只消费 `AgentHarness`**）

实测（`grep`）：

| 事实 | 证据 |
|---|---|
| `:app` 对 `:core` 的引用**只有** `JsonValue`/`JsonString`/`JsonObject` | 每个 1 处 |
| **app 主面完全没有引用 `AgentHarness`** | `grep -rn AgentHarness android/app/src/main/kotlin/` = 0 |
| UI 实际消费的是快照模型 | `PdshNavFacts` / `PdshNavHost` / `PdshRoute` / `PdshNavState` / `PdshHostAction` |

也就是说：**Android 走的是「宿主快照 + 路由」模型，不是「UI 消费 AgentHarness」模型。** `AgentHarness` 是接口 + `FakeHarness`（仅测试），没有任何生产实现。

### 后果（必须记清楚）

1. **P6 的验收「双端会话语义一致」无法通过预期路径验证**——那条路径（共享 `AgentHarness` 契约）在 Android 上不存在。
2. `IngressQueue`、`BackgroundExecutionFacts`、`narrowedTo` 目前**都没有消费者**。这是「做完了但永远不会出现」的**第五次**（前四次：11 个页面没接路由、context 行无生产者、入站附件无生产者、sessions 无 facts 适配器）。
3. 但**这个偏差本身不一定是错的**：快照模型能跑通真回合、能渲染 26 个页面、1348→1381 个测试全绿。它只是**和方案写的不一样**。

### 处置

- **不重构**。把 app 改成消费 `AgentHarness` 是一次大手术，而现有路径有真回合证据。
- **把偏差写进回执与 PR**，并**重述 P6 的验收**：从「双端经共享 `AgentHarness` 契约语义一致」改成「快照模型的字段语义与 Swift 侧 `AgentHarness` 的对应关系逐项对照」。
- `IngressQueue` 等三项标为**「已实现、待接线」**，不当作已完成（同 §19 的记法）。

## 38. `python3` / `jq` 修好了（本轮最重要的一条）

### 结果（设备 emulator-5558，真 key）

```
(1) python3 -c 'print(1+1)'   exit 0   stdout: 2   stderr: (空)
(2) jq -n '1+1'               exit 0   stdout: 2   stderr: (空)
```

修复前（11:07，旧产物）：

```
python3: EACCES: session-internal state under /dsh/home/sessions … (/dsh/home/sessions)
pdsh-shell: exit=1 program=python3 reason=backend-failed
```

### 根因（一句话）

**快照遍历把「执行面不可读」当成「遍历失败」。**

`walk()` 只容忍 `ENOENT`，而执行面策略**故意**对 `/dsh/home/{sessions,storages,tool-journal}` 返回 `EACCES`（`spec/v1/channel.md` §VFS 明文）。于是宿主自己的全量采集在 guest 跑第一条指令之前就被判死。

**为什么只有 WASI 工具挂**：Android `crossOriginIsolation=false`（`WebViewEngine.kt:136`）→ `supportsSynchronousVfs()` false → 两个 toolbox 走 `snapshotFallback` → **每次实例化全量遍历 preopen 树**；而 `cat`/`grep`/`ls` 走 shell 自己的 fs，不遍历。

### 证据链（三步，可复核）

1. **探针构建**：临时把 `isInvisibleToExec` 退回 `ENOENT`-only，并在 throw 处加标记；设备解包的 `worker-entry.js` = 3,776,358 B，**同一份文件里**同时有退回版函数和标记
2. **设备实跑**，标记出现在 guest stderr：

   ```
   python3: EACCES: … (/dsh/home/sessions) [PDSH_P2_MARK_SNAPSHOT_WALK_STAT path=/dsh/home/sessions code=EACCES]
   ```

   **这一步证明的是「抛错点确实是这里」**，而不是「我猜是这里」
3. **最终构建**（3,779,294 B）：标记消失，`isInvisibleToExec` = `ENOENT || EACCES`

### 修法

`isInvisibleToExec(code) = ENOENT || EACCES`——被拒子树**按不存在跳过**（不进 guest 视图、计入 `omitted`）；**EIO 等非策略错误仍然整体失败**（这条区分很关键：不能因为有 EACCES 就把所有错误都吞掉）。

回归测试改成**生产形状**（用真的 `VfsProxyError` + 真 `execReadDeniedMessage`，覆盖 stat 与 readdir），并新增「非策略错误必须仍然致命」。
**反向验证**：退回 `ENOENT`-only → `not ok 8`、`not ok 9`（10 个里 2 红）；恢复 → 10/10。

### 我在这条上错了两层，记录在此

1. 我说过「快照修复不是 python3 失败的原因」——**错**，它就是。
2. 我还把 `worker-entry.js` 还原成了设备原版，**把自己的修复一起弃掉了**。

**教训：修复投递到哪份产物，必须用「设备解包出来的字节里有标记」来证明，不能靠「我改了源码」。**

### 更正：「三份产物」表里 `shell-ext` 的位置

§33 写的表**有一个错**：

| 代码 | 在哪份产物里 |
|---|---|
| `wasi-toolbox`（python3/jq 的快照） | `worker-entry.js` |
| **`shell-ext`（`bridge.ts` / `ls`）** | **`image.tar.gz` 里的 `node_modules/@phone-dsh/dsh-shell-ext/lib/*.js`** |

手机 profile 从**镜像**加载 plugin，所以 `shell-ext` 不编进 `worker-entry.js`。P1 原先的验证计划因此需要「三处 grep」，这已写进它的收官清单。

### 错误码不一致也统一了

先证明了 `ls` 的 ENOENT 是**渲染**问题：底层 `lstat` 拿到的就是 EACCES，而 just-bash 内置 `ls` 对任何读失败硬编码 "No such file or directory"。

修法：`VfsNamespace.execReadDenial()` 与 `assertExecReadable` 共用同一句（顺带去掉了 `VfsProxyError` 重复追加的 `(path)`——旧消息里路径出现两次）；`ls` 在委托内置前先问 adapter。

设备实测：`ls /dsh/home/sessions` 与 `ls -l …` 均 **exit 2** + 同一句 EACCES + remediation；`ls /dsh/home` 仍 exit 0 正常列出。

### 快照成本（顺带量出来的，重要）

设备实测 `/dsh/home` + `/dsh/workspace` **只有 6 个文件**（三个内部根被跳过）。上限是 8192 条目 / 48 MiB / 单文件 64 MiB。

同一算法本地计时（macOS Node）：

| 规模 | 耗时 |
|---|---|
| 10 文件 / 10 KiB | 0.42 ms |
| 200 / 0.2 MiB | 0.95 ms |
| 1000 / 1 MiB | 3.74 ms |
| 1000 / 7.8 MiB | 4.21 ms |
| 4000 / 15.6 MiB | 14.62 ms |

**成本主要在全量复制字节**：`jq` 每次 dispatch 重采（`refreshSnapshotOnRun: true`），`python3` 每热实例一次。Android 上更慢，且每次多一次 structured clone。

**命名建议**：`snapshotFallback` → `snapshotFileView`、`refreshSnapshotOnRun` → `recaptureViewOnDispatch`。它在 Android 上是**唯一路径**，叫 fallback 会让下一个人以为是罕见的恢复分支。

### 还剩两个（已派 P8）

| # | 遗留 | 危害 |
|---|---|---|
| 1 | **`jq` 截断不 fail loud**：python 有 `requiredPreopens`，jq 没有 → 截断时 `snapshotFileView` 静默服务**残缺视图** | 安全相关 |
| 2 | 其它内建仍错：`cat`/`head`/`tail` 把 EACCES 说成 ENOENT；`find`/`stat`/`du`/`sort`/`od` 码对但无 remediation 行 | 契约一致性 |

## 39. 能力面三项缺陷已修，**由我独立复核**（不靠车道转述）

设备 `emulator-5558`，真 key，重新部署后的最终产物（`worker-entry.js` md5 `dc102c1f…`、`image.tar.gz` md5 `9e669dc8…`）。我用 App 内的 flash 子 Agent 逐条跑，再自己读 journal 的 `tool/result` 第一方原文：

| # | 命令 | 结果 |
|---|---|---|
| 1 | `python3 -c 'print(1+1)'` | **`2`** |
| 2 | `jq -n '1+1'` | **`2`** |
| 3 | `phone info` | `{"model":"sdk_gphone64_arm64","manufacturer":"Google","device":"emu64a","sdk":35,"release":"15","abis":["arm64-v8a"],"display":{…}}` |
| 4 | `phone files.list '{}'` | exit **127**：`this host does not provide that phone tool (host: only `phone info` is implemented); nothing executed` |
| 5 | `ls /dsh/home/sessions` | exit **2**：`EACCES: session-internal state under /dsh/home/sessions is not readable from an execution surface; …` |
| 6 | `ls /dsh/home` | exit **0**，列出 `AGENTS.md capabilities.json cordis.patch.yml profiles sessions storages tool-journal` |

### 变更的三项缺陷

| 缺陷（修复前） | 修复后 |
|---|---|
| `python3` / `jq` 100% EACCES，而能力清单声明可用 | 真能算；`2` |
| `phone <tool>` 全部 `unsupported … nothing executed`，清单声明 19 个工具 | 只声明 1 个真的能用的（`info`）；其余 127 + **点名** + hint |
| `ls` 把 EACCES 渲染成 ENOENT（just-bash 硬编码） | EACCES + 同一条 remediation 行，exit 2 |

### 门禁独立复核

```
bundle-freshness: 6 fresh, 0 stale, 0 absent   → PASS
android/tools/structure_check.py               → OK 11 checks passed
```
产物 md5 与车道报告**逐字节一致**（`dc102c1f…` / `9e669dc8…`）。

### 仍未解决的一条不一致（契约空白）

第 5 条与第 6 条并列时暴露：

- `ls /dsh/home` **能列出** `sessions` / `storages` / `tool-journal` 三个**名字**
- 但 `ls /dsh/home/sessions` 被拒（EACCES）

契约（`channel.md` §VFS）只写「execution surfaces **never see the bytes**」——**没说能不能看到名字**。

所以现在：名字可见、实体不可访问。这**不违反**契约字面，但两个入口给出不同结果，用户/模型会困惑。

两条路：
- **(a) 契约补一句**：「内部根的名字也不出现在执行面的目录列表里」→ 实现要把它们从 `readdir` 过滤掉
- **(b) 契约补一句**：「名字可见，实体不可访问」→ 保持现状，但要在文档里说明这是有意的

**我倾向 (a)**：能列出却打不开，比完全看不到更像 bug；而且「名字本身也是信息」（三个内部根的命名暴露了实现结构）。但这是契约变更，需要 spec owner 定。



## 40. 冷启动与故障注入数字（P5，自建 AVD，API 35）

> 节号说明：本节原计划写 `## 36`，但并行车道在本节写入前已占用 36–39（P7/架构偏差/python3/能力面）。
> 这里改为 40，不覆盖别人的章节；内容与命令不变。

> **一句话**：冷启动到 worker 就绪 **median 4.94 s**（10 次；min 3.38 / max 20.56，离群点有解释），首回合 TTFT **median 1.78 s**，单回合 RSS 峰 **median 289.3 MiB**。
> 五项故障注入里 **4 项恢复或诚实报告**；**后台 10 分钟这一项抓到一个真 bug**：回到前台后 D14 停在 `Draining`，worker 重连被 409 拒绝，界面仍显示「运行中/已连接」。另修掉一个「没有工具调用的已完成回合被判失败」的分类 bug（§40.3）。

### 40.0 环境、设备与口径

| 项 | 值 |
| --- | --- |
| AVD | 本车道自建 `pdsh35-p5`（`pixel_6`），**未使用** `emulator-5556/5558/5560/5562` |
| 端口 | `5564`（`emulator-5564`），启动参数 `-no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect` |
| 系统 | Android 15 / API 35，`sdk_gphone64_arm64`（`emu64a`），userdebug，arm64-v8a |
| 资源 | 4 vCPU、2 GB（`MemTotal 2,531,992 kB`）、1080×2400 @420 dpi |
| Emulator | 37.2.13.0 |
| 宿主 | macOS；测量时宿主上**同时跑着另外两条车道的模拟器**（`emulator-5556`、`emulator-5558`），CPU 争用存在（见 §40.1 的离群点） |
| 构建 | `:app:assembleDebug`，安装包 125,389,283 B；真 key 由 `run-as … cat > files/import-key.txt` 部署，首次启动导入后明文被删 |
| 时钟 | **全部用设备时钟**（`logcat -v epoch` 与 worker journal 的 `time`），不做宿主/设备换算 |

测量脚本（本车道新增，可重跑）：`android/tools/measure-coldstart-slo.py`。原始 logcat 逐次保存在
`android/build/p5-slo-first5/`、`android/build/p5-slo/`；故障注入的原始 logcat 与 journal 在
`android/build/p5-faults/`（都是构建产物，不入库）。

```bash
# 自建 AVD（用完删除）
echo no | avdmanager create avd -n pdsh35-p5 \
  -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_6
emulator -avd pdsh35-p5 -port 5564 -no-window -no-audio \
  -no-boot-anim -no-snapshot -gpu swiftshader_indirect &

adb -s emulator-5564 install -r -t android/app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5564 shell "run-as com.phonedsh.probe sh -c 'cat > files/import-key.txt'" \
  <<< "$PDSH_KEY"          # 值不写进回执；下一次启动导入并删除明文
adb -s emulator-5564 shell am force-stop com.phonedsh.probe

# 冷启动 SLO（5 次 × 2 批；脚本每次先 force-stop、清 logcat）
python3 android/tools/measure-coldstart-slo.py --serial emulator-5564 --runs 5
```

**指标口径**（括号里是日志锚点）：

| 指标 | 起点 → 终点 |
| --- | --- |
| `cold_start_ms` | `ActivityTaskManager: START u0 … com.phonedsh.probe` → `PDSHAppTurn: APP_WORKER_READY` |
| `worker_load_ms` | 引擎自报的 `worker assets: (reusing / ready) … in N ms`（`WorkerAssets.materialize()` 的实测；日志行差值含调度延迟，单列在原始 JSON 的 `worker_load_log_delta_ms`） |
| `overlay_load_ms` | `PDSHEngine: page started:` → worker console `webworker host: tree active (… data overlays=1 …)` |
| `ttft_ms` | `APP_TURN_BUTTON` → 该会话 WAL 第一条 `assistant/message` 行的 `time` |
| `ttft_first_text_ms` | 同上，但终点取 `stream` 里第一个 `block-start(blockType=text)` 的 `time`（更接近首 token） |
| `rss_peak_kb` / `pss_peak_kb` | `dumpsys meminfo com.phonedsh.probe` 的 `TOTAL RSS` / `TOTAL PSS`，回合前、回合中、回合后取最大 |

**一处必须纠正的口径**：`dumpsys meminfo | grep TOTAL` 那一行的**第一个数是 PSS，不是 RSS**；RSS 是第五列。
本节两者都报，`rss_peak_kb` 取 `App Summary` 的 `TOTAL RSS:` 字段。

### 40.1 冷启动 SLO：10 次采样

10 次 = 两批各 5 次（同一 APK、同一 AVD；第一批 11:20 前后，第二批 11:41 前后）。
每次的回合是同一个真模型提示 `只回答一个数字：1+1 等于几？`（无工具调用）；10 次会话的 `assistant/message` 文本逐个复核，全部是 `2`。

| # | cold_start_ms | worker_load_ms | overlay_load_ms | ttft_ms | ttft_first_text_ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 5031 | 12 | 1591 | 3102 | 3100 |
| 2 | 3379 | 5 | 1001 | 1532 | 1530 |
| 3 | 4196 | 30 | 1194 | 1750 | 1748 |
| 4 | 3712 | 17 | 1457 | 1669 | 1635 |
| 5 | 20559 | 294 | 2975 | 1678 | 1677 |
| 6 | 6104 | 27 | 2099 | 2925 | 2905 |
| 7 | 5836 | 11 | 1836 | 1493 | 1407 |
| 8 | 4842 | 14 | 1297 | 1809 | 1769 |
| 9 | 8107 | 15 | 2095 | 2352 | 2339 |
| 10 | 4851 | 9 | 1366 | 2010 | 1941 |

| 指标（ms） | min | median | max | n |
| --- | ---: | ---: | ---: | ---: |
| `cold_start_ms` | **3379** | **4941** | **20559** | 10 |
| `worker_load_ms` | **5** | **14.5** | **294** | 10 |
| `overlay_load_ms` | **1001** | **1524** | **2975** | 10 |
| `ttft_ms` | **1493** | **1779.5** | **3102** | 10 |
| `ttft_first_text_ms` | **1407** | **1758.5** | **3100** | 10 |

> `APP_WORKER_READY` 和 worker 的 `XL_DSH_READY 3080` 是同一条 console 消息触发的两条日志（实测相差 2–5 ms，
> 两条日志的线程不同、偶有先后）；用哪个做终点，数字不变。它们都发生在 `handshake: proto=1` 与
> `host HELLO sent` 之后——也就是说这个「就绪」已经包含了 HELLO，不是「页面加载完」。

单回合内存（同一批 10 次，单位 KB）：

| # | RSS 前 | RSS 峰 | RSS 后 | PSS 前 | PSS 峰 | PSS 后 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 288196 | 293968 | 290068 | 168992 | 173572 | 167235 |
| 2 | 290864 | 292684 | 290312 | 171854 | 172467 | 167615 |
| 3 | 293656 | 293656 | 290744 | 174609 | 174609 | 167829 |
| 4 | 297284 | 297284 | 291228 | 178141 | 178141 | 168293 |
| 5 | 279924 | 296100 | 293184 | 159021 | 172969 | 169478 |
| 6 | 287384 | 295672 | 294024 | 166841 | 173557 | 170398 |
| 7 | 288528 | 296644 | 293376 | 167554 | 173576 | 169721 |
| 8 | 282668 | 296756 | 293532 | 162882 | 175737 | 170021 |
| 9 | 285296 | 296720 | 295136 | 164085 | 173628 | 171176 |
| 10 | 286728 | 296392 | 293948 | 166640 | 175320 | 170462 |
| **min/median/max** | — | **292684 / 296246 / 297284** | — | — | **172467 / 173602 / 178141** | — |

**离群点与方差的解释（不是找借口，是口径的一部分）**：

- 第 5 次 20,559 ms：`host boot` 前卡了 **7,276 ms**、WebView 初始化卡了 **6,254 ms**；同一宿主机上还有两条模拟器在跑，属于 CPU 争用，不是代码路径变了。
- 两批的中位数不同（前 5 次 4.20 s，后 5 次 5.84 s），同一 APK、同一 AVD、同一提示。**10 个样本不足以给 P95**，本节只报 min/median/max。
- 首次安装后的**第一次**启动另有一次 64.9 MiB 的 bundle 落盘（`start: bundle copied … in 1032 ms`），这 10 次都在 bundle 已复用之后；所以 `worker_load_ms` 的中位数只有 14.5 ms。**新装首启不能拿这个中位数当预期**。

### 40.2 故障注入（注入 → 观察 → 恢复）

| # | 注入 | 是否恢复 | 一句话结论 |
| --- | --- | --- | --- |
| 1 | 回合中 `kill -9` renderer | **是** | 引擎 `Recovering → Running`、新 channel、新 HELLO；被打断的回合 `APP_TURN_FAILED reason=api_aborted`；恢复后新回合 `APP_TURN_OK` |
| 2 | 回合中 `am force-stop` | **是** | 重启后 `TURN_INTERRUPTED_PREVIOUS … reason=NO_CALLBACK`，journal `0 torn tail(s)`；会话还在，半个回合被显式报告 |
| 3 | 后台 10 分钟 | **否** | 后台信号后 30.4 s 回合死于 durability ack 超时；回前台 `scenePhase(active)` 被 `Draining` 拒绝，worker 409 循环 10 分钟；新回合 189.3 s 后 `session_create_unavailable` |
| 4 | 100,000 B 大输出 | **是（截断+诚实）** | 没有帧层拒绝；工具层按尾部截到 64,107 B，带 `[output truncated; full output: <path>]`；模型自己报出 100,000 / 64,001 / 14,379 三个数并指认完整副本 |
| 5 | overlay 重载 | **是** | 每次 worker 启动恰好一次 `tree active (… data overlays=1 …)`，renderer 重建后仍是 1，没有重复装载 |

#### 40.2.1 回合中杀 renderer

注入（renderer 是 isolated uid，`kill` 需要 `adb root`）：

```bash
adb -s emulator-5564 root && adb -s emulator-5564 wait-for-device
# 先发起回合（tap「跑一轮」），1 s 后：
RPID=$(adb -s emulator-5564 shell "ps -A -o PID,NAME" | grep sandboxed_process0 | awk '{print $1}' | sort -n | tail -1)
adb -s emulator-5564 shell kill -9 "$RPID"
```

观察（设备时钟，约 3 s 窗口）：

```
E/PDSHEngine  renderer gone: low-memory reclaim (didCrash=false); destroying and rebuilding the WebView
W/PDSHEngine  channel: renderer gone
I/PDSHEngine  webview destroyed (live=0, rendererGone=true)
I/PDSHEngine  state: Running(origin=http://127.0.0.1:46605, port=46605) -> Recovering
E/PDSHAppTurn APP_TURN_FAILED reason=api_aborted
I/PDSHEngine  recovered: Running(origin=http://127.0.0.1:46605, port=46605); the page reloads and reopens the channel
I/PDSHEngine  channel channel-2: open (live=1)
I/PDSHAppTurn APP_WORKER_READY
```

恢复用时：`kill` 到新 channel open **约 1.2 s**（11:22:04.698 → 11:22:05.899），到 `APP_WORKER_READY` **约 2.8 s**（→ 11:22:07.480）。
**回合被判失败，原因是 `api_aborted`**（通道 API 被中断），不是静默重试。
恢复后的新回合（同一 App 进程、同一 origin）：

```
I/PDSHAppTurn APP_TURN_OK session=session-ae87727a-… kinds=turn_started,user_message×4,
  assistant_message,usage,tool_call,tool_result,…,turn_ended reason=completed tool_edges=true
```

**顺带记录一个不在本车道可修范围的文案问题**：`didCrash=false` 只说明「不是崩溃」，不说明「低内存回收」。
我们用 `kill -9` 杀掉时它同样打印 `low-memory reclaim (didCrash=false)` —— 这是把未知原因说成了已知原因（§40.4 未修清单第 2 条）。

#### 40.2.2 回合中 force-stop

注入：回合开始约 1.2 s 后 `adb -s emulator-5564 shell am force-stop com.phonedsh.probe`，然后带同样参数重新启动。
重启后的恢复证据：

```
W/PDSHRecovery TURN_INTERRUPTED_PREVIOUS epoch=1793503356402 step=0 reason=NO_CALLBACK recorded_at=… age_ms=4956
I/PDSHHost     journal: recovered 1 session(s), 2521 bytes
I/PDSHHost     journal: open (1 session(s), 2521 bytes, 0 torn tail(s) removed)
```

界面（uiautomator 实读）：

> 上次回合被中断
> 第 0 步之后进程被杀（原因：NO_CALLBACK）；会话已从 WAL 恢复，该回合没有 turn/end 记录。
> 已按 fail-closed 处理；这条报告不会自动消失。

被杀会话的 journal（`session-005e3879-…/session.v4.jsonl`）：**17 行，0 行 JSON 解析失败**，
有 `turn/start`、4 条 user message、`session/title-llm-request`，**没有 `turn/end`、没有 `assistant/message`**。

**怎么读这个结果**：会话没有丢，文件不是半行 JSON（`0 torn tail(s)`）；那半个回合确实没有 `turn/end`，
恢复路径把它标成「被中断」，而不是补一条假的完成记录。**这是诚实，不是完整**——`step=0` 是因为 durable
marker 一直写 0，恢复文案只能说「第 0 步之后」。

#### 40.2.3 后台 10 分钟（失败项，真 bug）

注入：

```bash
# 发起回合 → 1 s 后 HOME → 等 600 s → 回前台
adb -s emulator-5564 shell input keyevent KEYCODE_HOME
sleep 600
adb -s emulator-5564 shell am start -n com.phonedsh.probe/.MainActivity
```

**进程没死**：HOME 前 pid=8096，10 分钟后仍是 8096（2 GB AVD 上没有触发 LMK）。**但连接死了**（回合在 APP_TURN_BUTTON 后 **52.0 s**、后台信号后 **30.4 s** 失败）：

```
D/PDSHHost  lifecycle signal: scenePhase(background)
I/PDSHHost  D14 Running -> Draining via scenePhase(background) at 1093298 ms (admission=closed, effects=4)
D/PDSHHost  effect 'arm the 20 s drain deadline' has no Notifier surface in this lane
D/PDSHHost  VFS mutation deferred: admission closed (D14)

# 30 s 后（worker 侧 durability 计时器）
D/PDSHEngine console ERROR: ws channel: durability ack wait timed out; restarting the connection
             AckTimeoutError: durability ack level 1 up to 400 for "vfs" was not acknowledged within 30000 ms
E/PDSHAppTurn APP_TURN_FAILED reason=incomplete: kinds=turn_started,user_message×4,assistant_message,usage,tool_call reason=-

# 之后 10 分钟，每 2–10 s 一次：
D/PDSHEngine console ERROR: WebSocket connection to 'ws://127.0.0.1:34945/channel' failed:
             Error during WebSocket handshake: Unexpected response code: 409
```

回前台：

```
D/PDSHHost lifecycle signal: scenePhase(active)
W/PDSHHost D14 rejected scenePhase(active) in Draining (ILLEGAL_TRANSITION):
           scenePhase(active) is not an edge out of Draining
```

界面仍显示 **引擎状态=运行中、通道=已连接、收帧=796、最近错误=—**，而 worker 的 WS 仍在 409 循环。
此时再点「跑一轮」：`session/create attempt 1…9 not answered (timeout)`（每 21 s 一次），
**189.3 s 后**才 `APP_TURN_FAILED reason=session_create_unavailable`，界面才从「运行中」翻成「失败」。

**根因（代码层）**：`spec/v1/budgets.md` §2 规定 `Draining → Parked` 由「background drain complete，或 20 s deadline」
触发；这两个出口的 effect（`ARM_DRAIN_DEADLINE` / `FORCE_DRAIN_DEADLINE` / `START_BACKGROUND_TASK`）
归 `:dsh.background`，而本 probe 的组合根**没有接这条 lane**。日志自己说了「no Notifier surface in this lane」，
但状态机仍然进了 `Draining` —— 进得去、出不来。409 来自 loopback 的「同一时刻只允许一个 channel」
规则：旧连接在宿主侧仍被视为 live（或至少没有被释放），worker 的重连因此被拒；本节只观测到结果，
没有进一步区分这两种情况。

**这是本节最重要的发现**：它不是「后台久了慢一点」，是**回到前台后 App 永久不可用**（直到 force-stop 重启）。
修它需要动 `:dsh`（接线 drain deadline / 后台 lane，或加 `Draining → Recovering` 的前台恢复路径），
不在本车道可写范围（§40.4 未修清单第 1 条）。

**定时器行为小结**：真正触发的只有 worker 的 **30 s durability-ack 计时器**；
App 侧 180 s 的 host/engine ready 超时、180 s 的回合超时、60 s 的 API 请求超时都没有参与
（回合在 30 s 时已经因流结束而失败）。`Draining` 的 20 s deadline **从未被 arm**。

#### 40.2.4 100,000 字节大输出

提示（真模型，工具是 `bash`）：

```
Run exactly this bash command: head -c 2000000 /dev/urandom | base64 | head -c 100000 .
Then report the exact byte count of the output you received, and whether it was truncated
(and by what). Do not re-run it with different parameters.
```

观察：

- **没有帧层拒绝**：logcat 里没有 frame-size / oversize / too-large 错误；`tool/result` 帧实际携带的是
  截断后的 **49,931 B** 文本，回合最终 `APP_TURN_OK … reason=completed`（模型跑了 **8** 次工具调用，
  `APP_TURN_BUTTON` → `APP_TURN_OK` **102.8 s**）。**100 KB 这个量级没有观察到帧上限**；不能据此推断更大帧也安全。
- **工具层截断**：落进会话的 `tool/result` 文本是 **49,931 B**（模型自己核算其中可见 ≈49,728 B），尾部有两条不同的说明：
  - `[output truncated; full output: /dsh/tmp/dsh-subprocess-c653e0/dsh-subprocess-1-1-c976bf12e1f9-stdout.log]`
  - `(Omitted 14379 bytes. Full formatted result stored at: /dsh/tmp/dsh-spill-7f05dd/session-44032d03a46b/2c302de79b93-bash.txt. Use read with offset/limit …)`
- **模型自己没有编**：它用工具量出 `wc -c` = **100,000**、渲染副本 = **64,107 B**（其中真实流 64,001 B，
  是原输出的第 468–1299 行；**前 35,999 B 被切掉**），并明确写「截断发生在 harness 的渲染层，不在命令；
  唯一完整副本是那个 stdout.log」。这些数字都能在同回合的另几条 tool/result 里复核。

结论：**截断是尾部截断（head 被丢），不是拒绝；错误是诚实的，而且可复核**。这不算 bug，
但「full output」和「Omitted … full formatted result」两个路径同时出现，容易让人以为前者是完整结果——
记录在 §40.5 的 open question 里。

#### 40.2.5 overlay / worker 重载

注入：renderer 杀（36.2.1）+ force-stop 重启（36.2.2/36.2.4），逐次数 worker 的 `tree active` 行。

| 启动 | `tree active` 次数 | overlay 计数 | `XL_DSH_READY` | modules |
| --- | ---: | ---: | ---: | ---: |
| force-stop 后重启（36.2.2） | 1 | `data overlays=1` | 1 | 641 |
| 首次启动（36.2.1，被杀前） | 1 | `data overlays=1` | 1 | 641 |
| renderer 重建后 | 1 | `data overlays=1` | 1 | 641 |
| 36.2.4 的冷启动 | 1 | `data overlays=1` | 1 | 641 |

**没有重复装载**：每次 worker 启动恰好一行 `tree active`，`data overlays=1` 没有变成 2；
两次启动也没有出现重复插件注册/重复 activation 的错误。overlay 的装载耗时就是
`overlay_load_ms`（page started → tree active，10 次 min 1001 / median 1524 / max 2975 ms）。

### 40.3 修掉的一个真 bug：没有工具调用的已完成回合被判「失败」

**现象**（修复前，同一个真模型、同一条 `只回答一个数字` 提示）：

```
E/PDSHAppTurn APP_TURN_FAILED reason=incomplete:
  kinds=turn_started,user_message×4,assistant_message,usage,turn_ended reason=completed
```

`turn/end` 明说 `completed`、`assistant_message` 也在，界面却显示「失败/原因：incomplete」。

**根因**：`DshTurnClient.TurnRun.sawTheFourEdges`（`android/dsh/.../turn/DshTurnClient.kt:66`）要求
`turn_started → tool_call → tool_result → turn_ended`；而 `ProbeEngineViewModel` 把它当成「回合完成」的充要条件：

```kotlin
val complete = result.sawTheFourEdges && result.turnEndReason == "completed"
```

一个不调用工具的问答回合永远凑不齐 tool 边，于是被标成失败。这与 `AppTurnState.Completed` 自己的
KDoc 矛盾（那里只说「Worker 报告 `turn_ended(reason=completed)`」）。

**修法**（本车道可写范围，`android/app/src/main/kotlin/…/ProbeEngineViewModel.kt`）：

```kotlin
val answered = result.events.any { it.kind == HostEventKind.ASSISTANT_MESSAGE }
val complete = result.turnEndReason == "completed" && answered
…
"APP_TURN_OK … reason=completed tool_edges=${result.sawTheFourEdges}"
```

工具边不再被丢掉：它们从「完成门槛」降级为 **OK 行里的独立观测**（`tool_edges=true/false`）。
`:dsh` 里的 `sawTheFourEdges` 没有改（不在可写范围），所以它的 KDoc 仍写着「the four edges the acceptance names」，
现在它只描述工具 lane，不描述回合是否完成——这一点留给 `:dsh` 车道下一轮改名/改注释。

**验证**：

- 修复后 10 次无工具回合 **10/10** `APP_TURN_OK … tool_edges=false`（§40.1 的原始 logcat）。
- 有工具回合仍 **`APP_TURN_OK … tool_edges=true`**（36.2.1 恢复后的那次，`tool_call/tool_result` 各 2 次）。
- 构建：`:app:assembleDebug` `BUILD SUCCESSFUL`（8 executed / 150 up-to-date）。

### 40.4 未修 / 测不出（连同原因）

| # | 项 | 状态 | 原因 |
| --- | --- | --- | --- |
| 1 | 后台回来 `Draining` 死锁 | **未修（真 bug）** | 出口 effect 归 `:dsh.background`，本车道禁写 `:dsh`；需要接线 drain deadline 或加 `Draining → Recovering` 恢复路径 |
| 2 | `renderer gone: low-memory reclaim` 文案 | **未修（真 bug，轻）** | 在 `:engine`，本车道禁写；`didCrash=false` 只能说明「非崩溃」，不能说明「低内存」 |
| 3 | 灭屏 / Doze 10 分钟 | **未测** | 本项只做 HOME 后台；模拟器 Doze 与真机不等价，且没有真机 |
| 4 | 真实 LMK / 内存压力 | **未测** | 2 GB AVD 上未制造内存压力；`kill -9 renderer` 不是 LMK |
| 5 | >100 KB 的帧上限 | **未测** | 按要求压到 100 KB 避免预算；没有找到帧层拒绝路径，更大帧的行为未知 |
| 6 | API 33 回退路径 | **未测** | 本车道只建了 API 35 AVD；5556/5558 属别的车道，未借用 |
| 7 | 冷启动 P95 | **测不出** | 10 个样本 + 宿主 3 个模拟器争用；只能给 min/median/max，给不出可信 P95 |
| 8 | 真机任何数字 | **未测** | 任务限定模拟器；掉电语义/OEM 查杀按原计划推迟 |
| 9 | iOS 对照数字 | **未做** | 本车道只产 Android 数字；iOS 侧不在本树 |

**「overlay」的口径说明**：Android 宿主不在 launch URL 里下发 `overlay` 参数（`boot.js` 支持 `overlay`/`overlay[]`，
但本组合根没有用），可观测的是 worker 自己的 `data overlays=1`（profile/patch 在 bundle 内）。
本节测的是**这个 overlay 的装载与重载**；如果原意是「宿主下发的 overlay patch」，那 Android 侧没有这条路径，
应记为「未实现」而不是「测不出」。

### 40.5 Open questions

1. **Draining 的出口归谁？** 接线 `:dsh.background`（要前台服务 + 通知，而 probe 的 Notifier 是 DISABLED），
   还是给 probe 加一条「回前台发现 `Draining` 就重建 host」的恢复路径？前者改 `:dsh`，后者改 app 组合根，
   两条都需要一次 lane 决策。
2. **probe 该不该在后台 drain？** 它没有任何后台任务；`Running → Draining` 之后所有 VFS 写入都被
   `admission closed` 拒绝。如果不接后台 lane，是否应该在 probe 里干脆不转发 `scenePhase(background)`？
   这是「服从 D14」与「App 可用」之间的取舍，不是本车道能单方面决定的。
3. **尾部截断**：工具输出按尾部截 64 KB，前 35,999 B 只能去 spill 里找。是否应该给 head/tail 双通道，
   或把「被切掉多少字节、切的是哪一端」直接写进 marker？现在模型要自己量，虽然它量对了。
4. **`step=0`**：`InterruptedTurnStore` 的 durable marker 永远写 0，恢复文案里的「第 0 步之后」没有信息量。
   是否要在每个 `step/start` 时更新 marker？这会增加写放大，需要预算决策。
5. **20.6 s 离群**：需要一台**不跑别的模拟器**的宿主重测 10 次，才能把「宿主机争用」与「冷启动真实方差」分开；
   本轮做不到（另外两条车道在跑）。

## 41. P5 四个 open question 的裁定

| # | 问题 | 裁定 |
|---|---|---|
| 1 | `Draining` 出口归谁 | **归 P10**：probe 不该 drain（它没有后台任务）+ 加通用恢复路径，**两件一起**。只做前者是治一个入口，只做后者是兜症状 |
| 2 | probe 该不该在后台 drain | **不该**。日志自己说了 `effect 'arm the 20 s drain deadline' has no Notifier surface in this lane`——**没有后台任务却进 drain，本身就是错的**。drain 之后 VFS 写入全被 `admission closed` 拒绝，是在惩罚用户切后台 |
| 3 | 尾部截断要不要给 head/tail 双通道 | **不用双通道，但必须把「切了哪端、多少字节」写进 marker**。现在模型要靠 8 次工具调用、102.8s 才量出「真实 100,000 / 流到 64,107 / 被切 35,999」——**这些数字本该由工具直接告诉它**。marker 从 `[output truncated; full output: …]` 改成 `[output truncated: kept last 64107 of 100000 bytes (head 35999 bytes dropped); full output: …]` |
| 4 | durable marker 的 `step=0` | **每个 `step/start` 更新，但覆写同一条 marker 而不是追加新记录**。恢复文案「第 0 步之后」没有信息量；覆写避免写放大 |

### 顺带记一条 P5 指出的口径问题

> Android 宿主不下发 `overlay` URL 参数（`boot.js` 支持但没用），可观测的是 worker 的 `data overlays=1`；若原意是宿主下发的 overlay patch，**Android 侧没有这条路径，应记「未实现」而非「测不出」**

按「未知 vs 未实现」的既有判据（§19）：**这是「未实现」，不是「测不出」**。已记。

### 数字的适用范围（不许外推）

| 项 | 只能这么说 |
|---|---|
| 冷启动 median 4941 ms | **API 35 模拟器、pixel_6、2 GB、宿主同时跑 3 个模拟器** |
| P95 | **给不出**（10 样本 + 宿主争用） |
| 真机 | **零数字** |
| 灭屏 / Doze | **没测**（模拟器 Doze 与真机不等价） |
| 真实 LMK | **没测**（`send-trim-memory` 实测 pid 不变；`kill -9` 不是 LMK） |

## 42. 逐条契约对照审计（P4，两版 APK 实测）

这是本轮**唯一一份「每条实测都有契约 file:line 对应」**的产物。方法：App 内 `deepseek-flash` 逐条跑，原始 `tool_result` 取自设备 `session.v4.jsonl`（不采信模型自述）。V1 = 10:24 APK，V2 = 11:49 APK。

### 符合契约的（5 条）

| 实测 | 契约 |
|---|---|
| `curl` 两个外网 host → `network-denied`，无字节出网 | `README.md:200` + `gateway-security.md:113-129`（§5 默认拒绝） |
| `/dev/tcp` 不存在、`/proc`/`/dev` 不存在、python `socket()` → `OSError 58` | `channel.md:259-261`（根表）+ `capabilities.json network.sockets=false` |
| env / grep / capabilities **0 凭据命中** | `gateway-security.md:64-66`「The Worker never holds the key」 |
| 三个可写根成功；`/dev/null` 写成功 | `channel.md:259-261`、`budgets.md:115-118` |
| 写 `/etc` → `ENOENT` + 「writable roots are …」 | 根表无 `/etc` |

提权请求 `sandbox_permissions=danger-full-access` 被 **fail-closed 拒绝**，且模型按指示停止而非绕过。

### 违反契约的（4 条）

| 实测 | 契约 | 处置 |
|---|---|---|
| `rg` 读 `sessions/storages/tool-journal` **并打印 JSONL 全文** | `channel.md:262-263` | **P12**（数据泄漏） |
| `cat`/`stat`/`ln` → `ENOENT`；`find` → `Permission denied` 无 remediation 句 | `channel.md:262-263` | **P8**（渲染未生效） |
| >128 MiB 写 → `redirection: total output size exceeded`，exit 126，**无 EFBIG** | `channel.md:265-272` | **P13** |
| `/dsh/config`、`/`、`/dsh/bin` 可写成功（含我们自己声明为 `image_readonly` 的 `/dsh/bin`） | `channel.md:259-261` 根表 + `capabilities.ts:753` | **P13** |

### 一条策略，四个渲染器（这是所有不一致的根）

| # | 渲染器 | 行为 |
|---|---|---|
| ① | VFS adapter | `EACCES: <sentence>` ✅ |
| ② | just-bash 内建（`cat`/`stat`/`ln`/`head`/`tail`…） | 硬编码 `"No such file or directory"` ❌ |
| ③ | **host accelerator（`rg`）** | **根本没有策略** 🔴 |
| ④ | `dsh-sandbox` | 把策略句里的 `"Permission denied"` 当成沙箱拒绝 → 给**提权重试**提示 ⚠️ |

④ 是对 ② 的放大器：`approval/policy=never` 下它 fail-closed（对），但**产品化后会把「契约拒答」呈现成「可提权的沙箱拒绝」**——用户会以为是权限问题而不是策略。

### 两个契约缺口（spec 没规定，所以只能记为缺口）

| 缺口 | 现状 |
|---|---|
| 内部根**名字**可见 | `find /dsh/home -maxdepth 2` 能列出 `sessions`/`storages`/`tool-journal` 三个名字，但 stat 全拒。`channel.md:263` 只写「never see the bytes」 |
| symbolic link 语义未约定 | `ln -s` 被 sandbox 拒绝（`Operation not permitted`）；`readlink` 只能验负例 |

### 我在这份审计上的裁定

| P4 的 open question | 裁定 |
|---|---|
| 内部根名字可见算不算违反 | **算**。规则改成「内部根对执行面**完全不可见**」（`readdir` 过滤掉），因为「能列出却打不开」比完全看不到更像 bug，且**名字本身也是信息**（暴露实现结构）。这条要改契约 + 实现，已记入待办 |
| EFBIG 应不应从 bash 重定向可见 | **应**。两个预算合法但要分开：重定向写文件受**文件预算**（`EFBIG`），`maxOutputSize` 只管**捕获输出**。已派 P13 |
| `/dsh/config`、`/`、`/dsh/bin` 该不该硬拒 | **该**。根表里没有的根就不能写；`/dsh/bin` 我们还自己声明了 `image_readonly` |
| WAL 砖化是否已修 | **未修完**。P9 在修，且已拿到 `/tmp/p4/wal-snapshot.tar.gz` 真实字节 |
| A 组是否要在 V2 上全量重跑 | **不用**。P8/P13 覆盖了全部 delta，其余命令在 P3 的 92 条对账里已覆盖 |

## 43. 12:08 原子构建：泄漏堵住 + 四条命令统一（我独立验证）

12:08:25/12:08:44/12:09:05 的一次**完整原子构建**（`worker-entry.js` md5 `9f23e752…`、`image.tar.gz` md5 `7773a50f…`、APK 125,452,623 B）同时包含三条车道的改动。我先确认了构建里到底有什么，再上设备验：

| 层 | 检查 | 结果 |
|---|---|---|
| 宿主 Rust | `.so` 里 `strings | grep "session-internal state under"` | **1**（P12 的宿主策略在） |
| image shell-ext | `recordExecReadDenial` / `appendedHard` | **3 / 6**（P8 的渲染层在） |
| image shell-ext | `EXEC_INTERNAL_ROOTS` | **3**（P12 的 Worker 兜底也在） |

**「三条车道撞车」是虚惊**：12:08 那次构建在 P12 的代码之后、P8 的构建窗口之内，一次就把三家都带上了。

### 设备实测（emulator-5558，装当前 APK，真实 key）

| # | 命令 | 结果 |
|---|---|---|
| 1 | `cat …/sessions/*/session.v4.jsonl` | **EACCES + remediation**（bash 层注入） |
| 2 | `stat /dsh/home/sessions` | **EACCES + remediation**，exit 1 |
| 3 | `ln /dsh/home/storages x` | **EACCES + remediation** |
| 4 | `find /dsh/home -name '*.jsonl'` | **EACCES + remediation** |
| 5 | **`rg -n session_ /dsh/home/sessions`** | **EACCES + remediation** ← **泄漏堵住** |
| 6 | **`jaq -r .type /dsh/home/tool-journal`** | **EACCES + remediation** ← **泄漏堵住** |
| 7 | `rg -n schema /dsh/home/capabilities.json` | **正常输出**（正控：非内部状态仍可读） |
| 8 | `python3 -c 'print(6*7)'` | `42` |
| 9 | `jq -n 1` | `1` |

第 7 条是这份验证里最要紧的一条：**修泄漏没有把正常读取一起禁掉**。没有它，前六条全绿也只能说明「把 `rg` 弄坏了」。

### 仍然存在的一处瑕疵（记下来，不掩饰）

四条命令现在是**两条消息**：内建自己仍打 `No such file or directory` / `Permission denied`，**然后** bash 层追加一行 EACCES + remediation。

```
cat: /dsh/home/sessions/…: No such file or directory          ← 内建自己的（仍是错的）
bash: /dsh/home/sessions/--dsh-workspace--: EACCES: session-…  ← 守卫追加的（对的）
```

契约要求「receive EACCES with a remediation line」——**满足了**。但第一行自相矛盾，读日志的人会困惑。

**残留待修**：让内建的那一行也用同一个 errno，而不是靠 bash 层纠正。这需要改 just-bash 内置的错误渲染（P8 的方向已经是「统一渲染层」，只差覆盖内建自己的输出）。

### 记录：这一族的完整教训

今晚「修好了但没生效」共 **6 次**，全部同根：

| 次 | 我以为改的是 | 实际跑的是 |
|---|---|---|
| 1–4 | 快照遍历 | 只在源码/错产物里，设备从不认识 |
| 5 | 我自己把 `worker-entry.js` 还原成设备原版，**弃掉了自己的修复** | 设备原版 |
| 6 | shell-ext 渲染层 | 只重建了 `worker-entry.js`，**image 没重建** |

**结论**：这个仓库的投递链条是「**三份产物 × 一个 CJS 降级步骤**」，任何一环漏掉都白干。现在有 `bundle-freshness` 门禁（6 产物 × 源目录 mtime）在拦它。


## 44. 原方案 M99 假设失效：真实门槛是 Chromium 124，polyfill 已有但门槛不认（P11）

### 44.1 四个特性的真实版本（逐个查 MDN BCD，不照抄方案）

| 特性 | Chrome | Firefox | Safari | 依据 |
| --- | --- | --- | --- | --- |
| `ReadableStream.prototype[Symbol.asyncIterator]` | **124** | 110 | 27 | `api/ReadableStream.json` → `@@asyncIterator`；caniuse `mdn-api_readablestream_--asynciterator` 列 4–123 不支持 |
| `ReadableStream.prototype.pipeThrough` | **59**（不是 67） | 102 | 10.1 | 同上，`pipeThrough` 条目 |
| `DecompressionStream("gzip")` | **80** | 113 | 16.4 | `api/DecompressionStream.json`（构造器与 `gzip` 格式均 80） |
| `Symbol.dispose`（可选） | **125** | 141 | preview | `javascript/builtins/Symbol.json` → `dispose`；`asyncDispose` 是 127 |

结论：**只有 async-iteration 要求 124**，其余三项在 109 上本来就满足（android-33 的探测日志逐项印证：`pipe-through:true`、`decompression-stream-gzip:true`）。

### 44.2 门槛改对：`FLOOR_MAJOR` 99 → 124，且探测改成测「垫片之后」

问题不在 `FLOOR_MAJOR` 一个数字。旧探测只问「原生有没有」：

```js
typeof ReadableStream.prototype[Symbol.asyncIterator] === "function"
```

而 worker 的第一条 import（`plugins/worker-entry/src/jsc-compat.ts`）**本来就会装这个迭代器**（WKWebView 车道为 JavaScriptCore 写的）。于是同一台机器上：worker 能跑，门槛却说不能跑。

改法（`WebViewKernel.kt`）：

- `FLOOR_MAJOR = 124`，KDoc 写清 caniuse/BCD 依据 + 我们自己的 android-33 实测；这个数字**只**产生 `DEGRADED` 与文案，`UNSUPPORTED` 仍由特性决定；
- `WebViewKernelProbe.SCRIPT` 在测量前**安装同源垫片**，并真实消费一个 chunk（只 `typeof` 会接受「有函数但不产出 step」的假实现）；
- `featureGateDetail()` 在 `missingRequired` 为空且版本 <124 时追加 `below baseline 124 (async iteration via the worker prelude)`。

`UNSUPPORTED` 的语义没变：缺必需 API 才拒；`DEGRADED` 是「能跑，但在原生基线之外」。

### 44.3 android-33（WebView 109.0.5414.123）实测

修复前，同一镜像、同一 APK（`FLOOR_MAJOR = 99`）：

```
I PDSHEngine: webview kernel: provider=com.google.android.webview/109.0.5414.123, vendor=google,
  Chromium 109 (provider 109.0.5414.123), verdict=unsupported,
  features=readable-stream-async-iteration:false,readable-stream-pipe-through:true,
  decompression-stream-gzip:true,symbol-dispose:true
I PDSHEngine: state: Running(http://127.0.0.1:41397) -> Failed(webview kernel cannot run the worker:
  missing readable-stream-async-iteration (Chromium 109 (provider 109.0.5414.123)))
```

修复后：

```
I PDSHEngine: webview kernel: ... Chromium 109 (provider 109.0.5414.123), verdict=degraded,
  features=readable-stream-async-iteration:true,readable-stream-pipe-through:true,
  decompression-stream-gzip:true,symbol-dispose:true
```

回合（`SERIAL=emulator-5572 bash /tmp/probe.sh '只回复这一句：P11 内核门槛已修正' p11-accept`）：

```
== launch (p11-accept)
I PDSHAppTurn: APP_TURN_OK session=session-2295917b-129a-4da6-8c90-0fa7539717b1
  kinds=turn_started,user_message,user_message,user_message,user_message,
  assistant_message,usage,turn_ended reason=completed tool_edges=false
== model reply
P11 内核门槛已修正
real 0m7.226s
```

**这是本车道最关键的一条：109 上真的跑通了一个回合，不是「探测说能跑」。**

### 44.4 「worker 只需要这一个特性」是错的——109 上还撞出三组

门槛放开后，`session/create` 先是 `gateway/internal`。把真实错误取出来（临时在 App 里直连 `/api/session/create` 打响应体，事后已删）：

| 步骤 | worker 报的真实错误 | 缺的 API | Chrome 起始 |
| --- | --- | --- | --- |
| `session/create` | `TypeError: session.snapshotEvents(...).toReversed is not a function` | `Array.prototype.toReversed/toSorted/toSpliced/with`、`String.prototype.isWellFormed/toWellFormed` | 110 / 111 |
| `session/prompt` | `AbortSignal.any is not a function` | `AbortSignal.any` | 116 |
| 下一步 | `scheduler is not defined`（`await scheduler.yield()` 无守卫） | `scheduler.yield` | 129 |

三组都在镜像里静态可见（`toReversed` 5 处、`toSorted` 5、`toSpliced` 6、`isWellFormed` 3、`toWellFormed` 2、`AbortSignal.any` 68、`scheduler.yield` 6），且都落在真实路径上。

修法是三个新垫片，与 `jsc-compat.ts` 一起由 `boot.ts`/`entry.ts` 在 entry graph 之前 import：

- `es2023-compat.ts`：`toReversed/toSorted/toSpliced/with`、`isWellFormed/toWellFormed`（规范算法，泛型于 array-like）
- `abort-signal-compat.ts`：`AbortSignal.any`（首个 abort 的 reason、已 abort 立即生效、触发后摘监听）
- `scheduler-compat.ts`：`scheduler.yield`（有 `postTask` 走 user-blocking，否则 `setTimeout(0)`）

**为什么 JavaScriptCore 车道没发现**：Safari 16.4/17 早就有了这些，JSC 只缺 `Symbol.dispose`/async iteration/`Promise.withResolvers`/`global`。Chromium 109 比 Safari 17 老，所以多缺三组。**「iOS 上跑通了」不能推出「Chromium 99 也能跑」。**

### 44.5 语义差异（ReadableStream 垫片 vs 原生）

实测（Node 22 原生 vs 本仓库垫片，同一段脚本）：

| 行为 | 原生（Chrome 124+） | 本仓库垫片 | 影响 |
| --- | --- | --- | --- |
| `for await` 消费 chunk | 一致 | 一致 | 无 |
| `break`/`return()` 后 `stream.locked` | `false`（解锁） | **`true`（仍锁住）** | 若之后还要 `getReader()` 会抛；DSH 拿完 body 不再复用，本车道未观察到问题 |
| 迭代器对象自带 `[Symbol.asyncIterator]()` | 有 | **无** | `for await (const x of stream[Symbol.asyncIterator]())` 会失败；DSH 都是直接迭代 stream |
| `return(value)` 把 value 作为 cancel reason | 是 | **否**（`reader.cancel()` 无参） | 取消原因丢失，行为不变 |
| 背压 | 每次 `next()` 一次 `read()` | 同 | 一致（拉模型） |
| `pipeThrough` 组合 | 原生 | 垫片只加在 `Symbol.asyncIterator`，`pipeThrough` 仍原生 | 无差异 |

三条差异都可修（`reader.cancel(v).then(() => reader.releaseLock())`、给迭代器加 `[Symbol.asyncIterator]() { return this }`），但会再动一次 3.7 MB 共享产物；本车道按「实测够用」记在这里，作为后续项。

### 44.6 R4 需要更新的具体文字（方案不在本车道可写范围）

`TonoWiki/briefs/2026-10-31-pdsh-android-port-plan.md` 第 430 行 R4 的「对策」列，把：

> 特性基线 ≤M99 + 按包名/UA 探测真实内核版本（勿按 versionName 误判）+ 运行时特性检测 + 诚实降级（§6.2）

改成：

> **原生基线 M124**（`ReadableStream` async iteration 自 Chrome 124 起才有；`pipeThrough` 59、`DecompressionStream` 80 均远低于此）+ 低于 124 由 worker 前置垫片兜底（`ReadableStream` 异步迭代、ES2023 数组/字符串、`AbortSignal.any`、`scheduler.yield`；Chromium 109 已实测跑通）+ 按包名/UA 采集真实内核版本（勿按 versionName 误判）+ 运行时特性检测（测「垫片之后」的 surface）+ 诚实降级（§6.2）

同时 §11 的 R4 风险等级应从「中高」上调或在描述里写明：**Chromium 99 不装垫片跑不了这个产品**，华为设备是否可用取决于垫片覆盖是否完整（109 已实测，99 未实测）。

### 44.7 产物重建

| 产物 | 字节 | 说明 |
| --- | --- | --- |
| `examples/probe-app/Bundle/worker/worker-entry.js` | 3,787,056（原 3,780,124） | 重新构建，加入三个垫片 |
| `examples/probe-app/Bundle/worker/worker-entry.js.map` | 7,832,817 | 同上 |
| `android/app/build/outputs/apk/debug/app-debug.apk` | 125,455,442 | 含新 bundle 的 APK（无临时诊断代码的验收版） |

`tool-worker*.js`、`web-boot.js`、`workflow-isolate.js` 未替换（本次未改它们的源；重建会只差注释里的相对路径，故不动，减少共享产物抖动）。

### 44.8 未验证

- 华为 `com.huawei.webview` 真机：**仍未验证**。109 通过说明「99 类内核有救」，但 99 比 109 还老（可能缺更多），没有设备就没有结论。
- 三个新垫片在 Chromium 109 上的**单元级**语义只由 Node 测试覆盖（`es2023-compat.test.ts`、`abort-signal-compat.test.ts`），设备侧只有「回合跑通」这一条端到端证据。
- `scheduler.yield` 垫片用 `postTask('user-blocking')` 的调度优先级是否与原生 `yield()` 等价：未测。

## 45. `rg` / `jaq` 泄漏已闭（两层）+ 契约缺口「名字可见」的最终裁定

### 修复（宿主权威 + Worker 兜底）

| 层 | 位置 | 作用 |
|---|---|---|
| **宿主（权威）** | `shell/crates/pdsh-core/src/policy.rs`（新）+ `vfs.rs` 的 `host()`（`metadata`/`read_dir`/`open_read` 的**唯一出口**）与 `canonicalize()` | 字节在宿主；所有加速器都过 `Ctx → Vfs`；宿主先 canonicalize（含 symlink），相对路径/`..`/符号链接都绕不过 |
| **Worker（兜底）** | `plugins/shell-ext/src/exec-read-guard.ts`（新）+ `subprocess-xl` 两处接入 | 拦常见 argv 形式与 cwd；**看不见 `rg` 自己 walk 出来的名字**，所以只是兜底 |

### 反向验证（这是本次最硬的证据）

| 去掉哪层 | 结果 |
|---|---|
| 宿主 `host()` + `canonicalize()` | `pdsh-core` 3 红、`pdsh-rg` 5/6 红、`pdsh-jaq` 3/4 红、`pdsh-ffi` 1/1 红；**唯一全绿的是 capabilities 正控** |
| Worker 兜底首行 `return undefined` | 11 红（8 单测 + 2 端到端 + 1 inversion），**3 个正控仍绿** |

**「正控仍绿」比「红了几条」更重要**：它证明守卫是**精确的**，不是把读能力一起关掉。

### 设备实测

```
rg -n session_ /dsh/home/sessions   → EACCES，exit 2
rg -n session_ /dsh/home            → 三条 EACCES（三个内部根），exit 2
rg --files /dsh/home                → 只列 AGENTS.md + capabilities.json，三个根各一条 EACCES
jaq . /dsh/home/{sessions,storages,tool-journal} → EACCES，exit 5
jaq .schema /dsh/home/capabilities.json         → "pdsh-capabilities/1"   ← 正控
rg -n . /dsh/home/AGENTS.md                     → 正常输出               ← 正控
```

### 契约缺口「内部根名字可见」的最终裁定：**隐藏名字**

P12 指出了这个裁定现在有了具体的代价：

> `rg --files /dsh/home` 现在打印 3 条 EACCES 并 **exit 2**（输出仍是部分的）。这符合 spec，但若有 DSH 工具把 exit 2 当整体失败需确认。**另一选择是从 `read_dir` 隐藏内部根（exit 0），但会与 `ls /dsh/home` 的语义分叉。**

**裁定：从 `read_dir` 隐藏内部根。** 三条理由：

1. **「能列出却打不开」比「完全看不到」更像 bug**——这是 UX 判断，也是契约语义的一致化。
2. **它顺带消掉 exit-2 的歧义**：名字不存在 → 没有拒绝可报 → `rg --files /dsh/home` 自然 exit 0，调用方不会把「策略拒绝」误读成「命令失败」。
3. **名字本身是信息**：三个内部根的命名暴露了实现结构（`sessions`/`storages`/`tool-journal` 直接说出了住着什么）。

**代价**：`ls /dsh/home` 从「列出 7 项 + 3 条错误」变成「列出 4 项、无错误」。那个「错误」本来也是假的——用户没法对策略拒绝做任何事。

**要改的地方**：
- `spec/v1/channel.md` §VFS 补一句：「内部根的名字也不出现在执行面的目录列表里」
- `vfs-namespace.ts` 的 `readdir` 过滤 `EXEC_INTERNAL_ROOTS`
- 宿主 `vfs.rs` 的 `read_dir` 同样过滤（否则 `rg --files` 仍能看见）
- 反向验证：隐藏后 `ls /dsh/home` 无错误行、`rg --files /dsh/home` exit 0、且**对内部根的显式访问仍 EACCES**（隐藏名字不等于放宽访问）

**这一条排 P13 之后做**（P13 现在正在改 `vfs-namespace.ts`）。

## 46. WAL 砖化：三种形态全部修复（P9）

### 形态 3（线上真凶）：adopted epoch 跨两段被误判

**根因就在一行**：`shell/crates/pdsh-wal/src/recovery.rs` 的 adopted-tail 分支原来要求**每个**段都满足 `first <= materialized_upto_mseq + 1`。

P4 的 epoch 8 第二段 `first=551`、watermark=518 —— 虽然它紧接第一段（`attested_tail=550`），仍被这一句判成：

```
segment wal/00000008.000001.xlwal starts at mseq 551 above the materialized
watermark 518; the gap above the copy cannot be replayed
```

**修法**：删掉这句；保留 `first <= attested_tail + 1`，靠后续 `check_retained_tail` 证明并集连续且覆盖 `last_mseq`。即 **「只有第一段受 watermark 约束」**。

`last_durable_epoch` 本来就不 gate adopted tail（只参与 `next_epoch`），**不是这次的原因**——这条排除了一个错误假设。

### 真实快照端到端恢复（最硬的证据）

```
P4 RECOVERED: next_mseq=583 acked_mseq=582 materialized=582
              adopted=[wal/00000008.000000.xlwal, wal/00000008.000001.xlwal]
```

**`583/582` 正是我之前根据 `last_mseq=582` 预测的数字。** 用的是 P4 的真实字节，不是重建的 fixture。

### 形态 2：大记录 torn tail 被预算误判

`tear.rs::has_complete_record_after` 在声称长度跑出文件末尾时，仍扫部分 body，耗尽 4 MiB budget → 返回 true → Corrupt。

**修法**：新增 `record.rs::incomplete_shape_agrees`——用记录自己的 `len` 与**已落盘**的 `op/mode/mflags/path_len/data_len` 对齐，**证明这是合法记录被截短**，直接判 torn tail，不扫 body。fallback 搜索保留并加防御性 cap。

**预算关系的结论很重要**：`channel.md` §3.1 允许单 mutation 15 MiB → 最大记录 ≈ 15.07 MiB，而 budget 只有 4 MiB。**所以不能靠加大预算解决**；合法形状必须由 fast path 证明，预算只约束「length/body 不一致」时的 corrupt-len 搜索（那里 fail loud 是对的）。

### 形态 1：0 字节段

未列出 → 排除出 planner + 成功恢复后删除 + `WAL_EMPTY_SEGMENT_DROPPED`；已列出 → 走 listed-missing 规则，`last_mseq > watermark` 仍 CORRUPT。

真实 P6 artifact（`/private/tmp/p6-matrix/emu-kill/after-reboot.x`）设备输出：

```
WAL_EMPTY_SEGMENT_DROPPED segment=00000024.000000.xlwal
WAL_EMPTY_SEGMENT_DROPPED segment=00000025.000000.xlwal
wal/1: on ... next_mseq=438, acked_mseq=437, durable_mseq=0
```

### 三条形态的反向验证（各自退回 → 各自红）

| 形态 | 退回后 | 恢复后 |
|---|---|---|
| 3 | Rust 报同一句 Corrupt；JVM 报 `materialized watermark 6` 同类 | 绿 |
| 2 | Rust `left: Corrupt { at: 0 }`；JVM `has a length or CRC failure that is not at its tail` | 绿 |
| 1 | `unlisted WAL segment … has no readable header` | 绿 |

**三条独立退回、三条独立变红** —— 证明它们是**三个独立的分类错误**，不是一个 bug 的三种表现。

### 设备证据

- 形态 3：append 链回合 → force-stop → 冷启动 `wal/1: on`、`next_mseq=570 acked_mseq=569` → 随后 `APP_TURN_OK`
- 形态 2：注入 9 MiB torn prefix → `WAL_TORN_TAIL_TRUNCATED … keep_len=40 dropped_bytes=4194304` → `APP_TURN_OK`
- 形态 1：真实 P6 artifact → 两个丢弃行 → `next_mseq=438`

**P9 如实标注了一条**：形态 2 的设备验证是**注入**的 torn prefix，不是真 kill 命中（模拟器上 8 MiB 的 append 窗口亚 50 ms，无法确定性命中）。真 kill 路径由 P4 的真实快照 + Rust/JVM 测试覆盖。**这种标注比「跑通了」有用。**

### 契约

`wal.md` 369 行（cap 370），新增 §7 zero-length、§7.2 两条 bullet（zero-length / adopted multi-segment「**only the first is bounded by `materialized_upto_mseq + 1`**」）、§10 step1 三分法 + step2 大记录 torn tail 条款。

### 一条裁定：`0 < len < header_size` 的段怎么算

P9 问：0–39 字节但非 0 的 header 现在仍按「非零 header 损坏」fail loud（我先前给的三分法表就是这么分的），P6 的决策文档建议按 `<40` 放宽。

**裁定：`len < header_size` 一律可丢弃**，理由是**判据要落在「能不能存在记录」上**：

| 段长度 | 可能有几条记录 | 处理 |
|---|---|---|
| `0` | **0 条** | 可丢弃 ✅（**已实现**） |
| `0 < len < header_size`（40） | **0 条**（连一个完整 header 都没有） | **建议可丢弃——本文的裁定，但未实现，且与 landed spec 冲突** |
| `len >= header_size` 且 header magic/CRC 坏 | 可能 > 0 条，但无法可信解析 | **fail loud**（不变） |

前两行的共同点是「**结构上不可能含记录**」，所以丢弃不丢数据；第三行才可能丢。

> **⚠️ 更正（2026-11-01 独立审计发现）：本文上一版把第二行写成「本轮放宽」，那是错的。**
>
> - **实现**：`core/.../WorkspaceLog.kt` 只特判了 `bytes.isEmpty()`。`1 ≤ len < 40` 的段仍然走到
>   `recovery.rs` 的 `header_error` → `unlisted + !header_ok` → **`WAL_CORRUPT`**。
> - **spec**：`wal.md:248-249` 明确写着「a non-zero segment whose header magic, format,
>   reserved, length or CRC is wrong is **not** this case … so `WAL_CORRUPT` stands」。
> - **测试**：`ZeroLengthSegmentTest` 五条用例全是 `ByteArray(0)` 或完整 40 字节坏 magic，
>   **没有一条覆盖 1–39 字节**。
>
> 所以「放宽」只存在于这一节文字里。**这条裁定需要一次 spec 决定**（`wal.md` 那句把
> 「没有完整 header」和「header 被覆盖」两种情形混在一起），**不是实现能单方面决定的**。
> 在 spec 改之前，实现照 spec fail loud 是**正确的**——但**它是一条与原 🔴 形态 1 同类的砖化路径**：
> 掉电撕裂 40 字节 header 写会留下 1–39 字节的段，那会让工作区进 `Failed`。
>
> 保留本裁定作为**待决提案**，附上它需要的三件事：改 `wal.md:248`、改
> `WorkspaceLog.kt:779` 的判据为 `bytes.size < WalSegmentHeader.BYTES`（仅 unlisted 段）、
> 给 `ZeroLengthSegmentTest` 补 1–39 字节向量（含 listed 不可放宽的反例）。

## 47. Draining 死胡同已闭（P10）——第三个 🔴 关闭

### 根因比初诊更硬

P5 说「`Draining→Parked` 的出口 effect 归 `:dsh.background`，probe 没接」。P10 查到更根本的：

> **`ControllerSignal.DrainCompleted` 在任何 main 源集都没有生产者**（只有测试）。
> `ARM_DRAIN_DEADLINE` / `START_BACKGROUND_TASK` 只是 notifier lane 的 debug 行。

所以 `Draining` **结构上就是终态**——不是「接线漏了一根」，是**出口没有任何执行者**。

### 修法：补执行者 + 用既有边，不新增状态机边

| 件 | 内容 |
|---|---|
| (a) 补出口执行者 | 新增 `DrainLane`：epoch close（fsync 在 `HostWal.closeEpoch` 内）→ worker 真停 → feed `DrainCompleted` |
| (b) 恢复用**既有** D14 边 | 不加 `Draining→Running`（`budgets.md` §2 明写 "No other edge exists"）——而是 **drain 走完 → Parked → 把同一个 `scenePhase(active)` 重喂** |
| (c) 的替代 | 保留 background 转发，但 drain 在进程内完成，**不需要前台服务** |

**算的一笔账**：device 上 `closeEpoch` **52 ms**、`durable_upto=6`。所以 `START_BACKGROUND_TASK`（「跑 drain 期间保活」）对一个 52 ms 的操作**没有必要**；probe 没有 service 就诚实报 `no background window`，不静默丢。

### 设备验证：后台 10 分钟 → 回前台 → 能跑回合

```
12:04:23  D14 Draining -> Parked via drainCompleted   (admission=closed)
   ↓ 后台等 10 分钟
12:14:22  D14 Parked -> Recovering via scenePhase(active)
12:14:22  worker start requested by 'scenePhase(active)' from Stopped
12:14:22  D14 Recovering -> Running via leaseCheckResult(verified=true)  (admission=open)
12:14:23  APP_WORKER_READY
12:14:40  APP_TURN_OK … reason=completed tool_edges=true
```

drain 那一段：`Running -> Draining` → `closing the epoch now (deadline in 19994 ms; no background window…)` → `epoch closed, durable_upto=6` → `stops the worker` → `Draining -> Parked`，**全程 52 ms**。

**「20 s 是上界不是等待」**——超时只放弃「等待」，**从不 cancel close**。这条设计判断很关键：半截 fsync 就是撕裂纪元，比多变砖更不能接受。

### UI 撒谎修了（这是 P5 报的第二个症状）

`ProbeEngineViewModel` 暴露 `hostState`（`host.state`）→ 主行改为「宿主状态」= D14 label：

| D14 状态 | 显示 |
|---|---|
| `DRAINING` | 收尾中（不可用） |
| `PARKED` | 已暂停（后台） |
| `RECOVERING` | 恢复中（不可用） |
| `BACKOFF` | 等待网络（不可用） |
| `RUNNING` | 运行中（**唯一绿色**） |

第二行 `D14 <wireName> · admission <open\|closed>`；通道行**只有 admission open 才显示「已连接」**，否则「宿主不可用」；新增不可关闭横幅「宿主不可用：`<wireName>`」；`跑一轮` 仅 admission open 可用。

设备实测（wifi off 造出 `Running→Backoff`，与 Draining 走同一段 UI 代码）：`宿主状态 等待网络（不可用）` / `D14 Backoff · admission closed` / `通道 宿主不可用` / 横幅 `宿主不可用：Backoff` / `跑一轮` 灰。

### 反向验证

| 去掉什么 | 结果 |
|---|---|
| `drain.arm` | 4/5 红，`expected:<PARKED> but was:<DRAINING>` |
| 回前台的恢复路径 | 1/5 红，**红字正是设备上那一行** `D14 rejected scenePhase(active) in Draining (ILLEGAL_TRANSITION)` |

**第二条尤其好**：测试的红字与线上日志**逐字相同**。这说明测试复现的是真实故障，不是构造的断言。

### 新发现：这是**一类**问题，不是一个

P10 顺手查出一个状态机里的**五个信号没有生产者**：

| 信号 | 后果 |
|---|---|
| `DrainCompleted` | **已修**（本轮） |
| `START_RETRY_SCHEDULE` / `RetryAfterElapsed` / `RetryProbeSucceeded` | `Backoff` **永久停住**（P15 在修） |
| `PERSIST_HOST_STATE` | 每次 boot 都 `COLD_START`；Parked 期间被杀走冷启动而非 `PARKED_RESUME` |
| `PlannedRestartRequested` | 无生产者 |
| handoff / reclaim 相关 | 无生产者 |

**根因是同一个**：状态机是**从契约推导**出来的（D14 表定义得很完整），但**实现只接了主路径**（Running 那条）。所有「异常状态」的出口都停在纸面上。

**这才是这三个 🔴 的共同来源。** 修一个不够，需要把「每个状态的出口都有执行者」当成本轮的验收项。

### 一个方法学限制：所有设备证据都来自共享工作树

P10 主动标注：

> 设备验证用的 APK 构建自**共享工作树**，其中含别的车道未提交改动，证据不能单独归因到 HEAD。

**这条对整个项目成立。** 等全部车道收工、树干净之后，需要一次**归因明确的最终验证**。在此之前，「已验证」的含义是「对那一刻的树验证过」，不是「对 HEAD 验证过」。

## 48. 垫片与规范对齐（P14 + P17）

### P14 纠正了我一个前提

我在任务里暗示「原生 `return()` 后 `locked` 仍为 true」。**只对手动 `getReader()` 成立，对异步迭代器不成立**：

| 来源 | 结论 |
|---|---|
| MDN `ReadableStream` | 「While iterating, the stream is locked … **This lock is released when the loop exits**」 |
| [Streams 规范](https://streams.spec.whatwg.org/#rs-asynciterator) | `return` = `ReaderGenericCancel` → **同步** `ReaderRelease` |
| Node 22 实测 | `it.return('r')` 后**同步 `locked=false`**；自然读完也是 `false` |

**所以 `.finally()` 是错的**（同步窗口内仍 `locked=true`）。正确是同步 `release()`，并加 `lockedSynchronouslyAfterReturn` 钉住。

六条反向验证，最后一条最硬：**把 HEAD 的旧实现放回去跑新测试 → 8 条红**。

### P17 做得比要求更好：同一个函数对象，不是委托

我要求「让 `@@asyncIterator` 委托给 `values`」。P17 做成了**同一个函数对象装两次属性**，并给了规范依据：

> [Web IDL §3.7.10](https://webidl.spec.whatwg.org/#js-asynchronous-iterable)：「Let F be CreateBuiltinFunction(steps, 0, "values", «», realm). Perform ! CreateDataPropertyOrThrow(target, "values", F). If definition has a value asynchronously iterable declaration, then perform ! DefineMethodProperty(target, %Symbol.asyncIterator%, F, false).」

于是：`values` 是**可枚举 data property**、`@@asyncIterator` 是**不可枚举 method property**，指向**同一个 F**——与规范逐字同构。

兜底策略也对：引擎只有其中一个名字 → 缺失那个**别名到原生函数**（绝不另造实现）；两个都在 → 完全不碰。

### `{preventCancel:true}` 的规范依据（原文）

> [§4.2.5](https://streams.spec.whatwg.org/#rs-asynciterator)：「By default, calling the async iterator's return() method will also cancel the stream. **To prevent this, use the stream's values() method, passing true for the preventCancel option.**」
>
> return 算法：「If iterator's prevent cancel is **false**: … ReaderGenericCancel … ReaderRelease. Return result.」否则「**Perform ! ReadableStreamDefaultReaderRelease(reader).** Return a promise resolved with undefined.」

### preventCancel 的可观测断言：双重证明

不只「cancel 没被调用」，还有**遗留 chunk 仍可读**：

| 证明 | 观测 |
|---|---|
| 底层 `cancel` 从未运行 | `cancelled: []` |
| 提前退出后剩余 chunk 仍可读 | 同一 stream 的**第二个迭代器**得到 `[2, 3]` |

对照：`for await … break` 默认仍 cancel（`defaultCancelled: ['undefined']`）。**12 个场景**（原 8 + 4 新）。

### 第三条反向验证解开了一个陷阱

把 `@@asyncIterator` 装成**另一个行为等价、同名 `values` 的包装函数** → 4 红，而核心那条是：

```
not ok 9 : values() and @@asyncIterator must be the same function object
           + [Function: values]   - [Function: values]
```

**两边打印名相同，只有函数身份能抓住它。** 行为场景**全绿**——说明这条结构断言不可省。

**这是一条方法论收获**：行为测试（parity）抓不到「结构不对但行为一样」的实现，必须另有身份断言。

### 顺带：`throw()` 的超集

原生没有 `throw`，我们的垫片有（`fixtures/` 依赖）。KDoc 已写明：

> `throw(error)` is a superset of the native async iterator … `for await`/`AsyncIteratorClose` never call it, so it does not affect protocol conformance. Because it is outside the protocol it always cancels with the error, releases the reader and rejects, **even when the iterator was created with `preventCancel`**.

### 它顺带指出的漂移（已派 P18）

> `android/engine/.../WebViewKernelProbe.SCRIPT` 自述是 prelude 的副本，**目前仍只装 `@@asyncIterator`**。能力门禁不受影响，但「两份算法」现在只是部分对齐。

**这和之前那个 bug 是同一族**：原来「探测问原生、worker 跑垫片」→ 能跑的内核被判成不能跑；现在「探测装半个垫片、worker 装完整垫片」→ **测量的东西与被测的东西不是同一个**。

已派 P18，要求不能只补副本，**必须加一条机器检查让漂移变红**（「必须手工同步两份代码」的机制迟早会漂，今晚已有 6 次同类事故）。

## 49. WASI guest 不再把「被拒」说成「不存在」（P16）

### 修前：一个假陈述

```
$ jq . /dsh/home/sessions
jq: error: Could not open file /dsh/home/sessions: No such file or directory (os error 44)

$ python3 … open("/dsh/home/sessions")
FileNotFoundError: [Errno 44] No such file or directory: '/dsh/home/sessions'
```

**`/dsh/home/sessions` 存在**，只是不可读。`ENOENT` 断言「不存在」是**假话**，模型会据此得出「这台设备上没有会话」。

### 修法：快照把「拒绝」记录下来

```ts
export interface VfsSnapshotDenial {
  readonly path: string      // 被拒子树的绝对路径
  readonly code: 'EACCES'
  readonly message: string   // remediation 原句（去掉 "EACCES: " 前缀）
}
// VfsSnapshot 增加：readonly denied: readonly VfsSnapshotDenial[]
```

真实抓取（`/dsh/home` 下只有一个文件）：

```json
{"denied":[{"path":"/dsh/home/sessions","code":"EACCES","message":"session-internal state under /dsh/home/sessions is not readable …"}],
 "omitted":2, "entries":["/dsh/home","/dsh/home/notes.md"]}
```

`SnapshotWasiVfs` 对命中被拒前缀的 `stat`/`readdir`/`readFile`/`open`/`read` 及写/删/改名**一律抛 EACCES + 原句**。

### WASI 的 errno 编号与 Linux 不同（这条容易搞错）

**WASI preview1: `EACCES = 2`、`ENOENT = 44`**（不是 Linux 的 13/2）。所以实际打印是：

| 程序 | 输出（真实 wasm 工件） |
|---|---|
| `jq` | `EACCES: session-internal state under …`（诊断行）+ `jq: error: … Permission denied (os error 2)` |
| `python3` | 同一句诊断 + `PermissionError: [Errno 2] Permission denied: '/dsh/home/sessions'` |

**两份信息都在**：我们自己的 remediation 原句（可行动）+ guest 自己的 errno 措辞（程序可判）。

### 列目录仍不可见（这是与 §45 裁定一致的那半）

```
$ python3 -c 'import os; print(sorted(os.listdir("/dsh/home")))'
['notes.md']
```

两层保证：capture 对被拒项**不入 `entries`**（`readdir` 被拒时还会撤回刚 push 的目录项）；`SnapshotWasiVfs.readdir` **再按 `denied` 过滤**（覆盖「快照里仍带该 entry」的旧/外来快照）。

### 两条独立反向验证（对应两个正交性质）

| 去掉什么 | 结果 |
|---|---|
| 记录被拒根 | 端到端退回 `No such file or directory (os error 44)`；`vfs-snapshot.test.ts` 11/14/15 红，**13（view 的 readdir 过滤）仍绿** |
| 列目录过滤 | `12`/`13` 红，实际值 `['notes.md','sessions']`；**11（EACCES）仍绿** |

**两条各自红、各自不影响对方**——证明「访问报 EACCES」与「列表不出现」是**两个正交性质**，不是一个开关的两个副作用。

### 它如实报出的一处未完成（重要）

> 与任务假设冲突：该 pre-fix 包上 `ls /dsh/home` 实际**列出**了 `sessions`/`storages`/`tool-journal`（exit 0），`stat /dsh/home/sessions` 打 `No such file or directory`（另有单独一行 `bash: … EACCES: …`）。即 **shell 侧的「列表不可见」尚未成立**，属 shell-ext 车道。

**所以 §45 那条裁定只完成了一半**：WASI guest 侧已经「不列名 + 访问 EACCES」，**shell 内建命令侧仍然列出名字**。剩下这半要在 `shell-ext`/`vfs-namespace` 做，而 P13 正在改那两个文件。

## 50. 两个写侧契约缺陷（P13）+ 一个新发现的砖级 bug

### A：`EFBIG` 被输出预算抢先，文件预算从未被问到

**拦截链路**：`shell.ts:122` 把引擎的 `maxOutputSize` 设成 `MAX_FILE_SIZE + maxBytes`（8 GiB 档 = **134479872 = 128 MiB + 256 KiB**）；引擎在**写重定向目标之前**就把整条结果记进 `executionScope.outputBytes`：

```
ys(): n.length>0 && (t = e.executionScope.accountResult(t,"redirection"))
```

所以第 129 个 MiB 先撞输出上限，`filesystem.ts:1137/1170` 的文件预算**一次都没被问到**。

**修法**：`patch-just-bash.mjs` 加一条 byte-guarded replacement，**删掉写之前的 `accountResult(t,"redirection")`**，保留写之后的（它本来就只记留在 stdout/stderr 的字节）。`PATCHED_SHA256` `124182…` → `a93d71b3…`。

**两个预算现在可区分**：

| | 文件预算 | 捕获输出预算 |
|---|---|---|
| 触发 | 写文件超 `single_file_limit` | 结果累计 > `maxOutputSize` |
| 输出 | `EFBIG: File too large: … would be N bytes; a file is limited to 128 MiB` + `reason=limit-refused` | `bash: … total output size exceeded` + `reason=output-truncated` |
| 退出 | **1** | **126** |

### B：写根守卫原来**没有执行点**

查证：`writable()` 只被 `writableRoots()` 用于 preopen 表，**没有任何写路径调用**；`WORKER_WRITABLE_ROOTS` 只在 `rethrowWrite` 里给错误**追加提示**，不拦。

所以 `/`、`/dsh/config`、`/dsh/bin`（我们自己声明为 `image_readonly`）全是**写穿**的——因为 MemoryVfs 没有只读概念。

三层修：namespace 单点（`writeRoots`/`assertWritable`/`WRITE_DENIED`）+ adapter 门（image，设备上生效的就是这层）+ 渲染修正（just-bash 的 `qe()` 会把 `/home`/`/tmp`/`/etc` 改写成 `<path>`，所以错误只带 errno + marker，由 `ExecWriteDenialLog` 在出口修复）。

设备实测：五个合法根成功；四个非法路径**逐字节同形**的 EACCES + `writable roots are …`。

### 反向验证两条

| 项 | 结果 |
|---|---|
| A（换回旧引擎） | `redirection: total output size exceeded` 回来；redirect 与 multi-file 两条 FAIL，**capture 一条 PASS**（证明不是把所有限额关掉） |
| B（`writePolicy:false`） | 四个路径 `exit=0 exists=true`（修前行为）；打开后全 EACCES |

**A 的「capture 一条 PASS」很关键**：它证明修复是**分开两个预算**，不是**取消限额**。

### 裁定：P2 的句子扩成 5 根，接受

P13 把 `writable roots are …` 从三根扩成五根（加 `/tmp`、`/dev/null`），并改了 3 处既有断言。

**接受。** `channel.md:259-261` 的根表就是 5 个（含 `/dev/null`），P2 那句只列三根是**不完整**的。补全是修对的方向。

### 新发现（砖级，已派 P19）：写满 128 MiB 后 App 每次启动崩溃

```
写满 128 MiB → 重启 → WAL 恢复该 segment → OutOfMemoryError
             （AbstractStringBuilder / JsonParser.parseString）
→ 每次启动崩溃，用户无法自救
```

**2 GB 的 AVD 上必现。**

这是**契约允许的操作的直接后果**：`budgets.md` 允许单文件 128 MiB，P13 刚让 128 MiB 写入成功——**允许写进去，却恢复不了**。

**这条说明一件事**：契约、写入、恢复三处必须同时成立，只修一处是把问题往后推。

### 一条跨车道问题：我们给了模型一条做不到的建议

设备上写被拒后，模型看到的最后两行**不是我们产生的**：

```
[sandbox: file access denied under workspace-write mode]
[sandbox: escalation available — retry this exact command once with sandbox_permissions
 (the narrowest wider mode that suffices) + justification; the approval prompt asks the user]
```

这是 pinned DSH harness 对 bash 工具的装饰。**而 phone profile 没有任何可用的提权档**——模型照做会失败。

**这和「点了没反应的按钮」是同一族：给出一个做不到的行动建议，比不给建议更糟。** 需跨车道决定（让 harness 认 `pdsh-shell:` trailer，或让我们的拒答形态避开该装饰）。

## 51. 探测工具本身不可信（P18）——「装 1 个 vs 装 14 个」

### 漂移的规模

worker 前导（`boot.ts` 的四个 import）装 **14** 个属性；修前 `WebViewKernelProbe.SCRIPT` 只装 **1** 个：

```
Missing 13 of 14:
  Symbol.dispose / Symbol.asyncDispose / ReadableStream.prototype.values
  Promise.withResolvers / global
  Array.prototype.toReversed / toSorted / toSpliced / with
  String.prototype.isWellFormed / toWellFormed
  AbortSignal.any / scheduler.yield
The probe currently installs:
  ReadableStream.prototype[Symbol.asyncIterator]
```

**所以改之前的门槛几乎是在测「空 surface」。** 它能放行 WebView 109 只是因为那一个属性恰好装对了，**不是测量准确**。

### 一处归属纠正

`AbortSignal.any` / `scheduler.yield` / ES2023 方法**不在** `jsc-compat.ts`，而在 `boot.ts` 另 import 的三个模块：

| 模块 | 属性数 |
|---|---|
| `jsc-compat.ts` | 6 |
| `es2023-compat.ts` | 6 |
| `abort-signal-compat.ts` | 1 |
| `scheduler-compat.ts` | 1 |

### 为什么不能「消除手抄」

四条理由都站得住：

1. **realm 不同**：probe 由 `WebView.evaluateJavascript` 在**页面** global 求值，前导在 **Worker** 自己的 realm。**页面求值只能复用「同一引擎二进制」这个前提，无法观察 Worker 实际得到的 surface。**
2. **没有可加载的独立前导产物**：前导是 TS，被 esbuild 打进 `worker-entry.js`。
3. **`evaluateJavascript` 是同步的**：没有 `import`/`await`/异步取 asset，而 probe 还必须在坏页面上可跑。
4. 把整个 `worker-entry.js` eval 进页面会**启动第二个 DSH runtime**。

### 机器检查（不是「补一遍」，是「不同步就红」）

| 测试 | 抓什么 |
|---|---|
| `boot.ts` 的 import 清单恰好是 4 个模块 | **加第 5 个前导模块 → 红**，提示扩展抽取器 |
| probe ⊇ prelude（`Missing N of M` 逐行点名） | 漂移 |
| `values` 与 `@@asyncIterator` **同一函数对象** + 描述符 | 结构（P17 的教训） |

实现方式：**跑真实的 installer**（不是正则抓源码），在「全缺」的 stub scope 上执行，拦截 `Object.defineProperty` 记录 `(carrier, key)`；探测侧从 Kotlin 抽出 SCRIPT，在子进程里先删掉全部原生属性再 eval，同样拦截记录，两边对比。

反向验证点名：

```
Missing 1 of 14:
  - ReadableStream.prototype.values
```

### KDoc 改成了可验证的表述

> The copy is therefore **verified, not promised** … Adding a prelude patch without mirroring it here is **a red test, not a silently weaker measurement**.

**这句措辞是全项目该学的**：不说「我们保证同步」，说「不同步会红」。

### 裁定：接受 probe 在页面 realm 打更多补丁

P18 问：probe 现在会在页面装 `global`、ES2023、`AbortSignal.any`、`scheduler.yield`，要不要为了「页面干净」把不变量收窄到「探测测量到的能力」？

**裁定：不接受收窄。** 理由：
1. probe 的职责是测「worker 会得到什么」，而 worker 得到全部 14 个
2. 收窄不变量 = 重新引入盲区 = 回到今天这个 bug
3. patch 幂等且同源，代价可控

### 这一类问题今晚出现了两次

| 次 | 形态 |
|---|---|
| 第一次 | 探测问**原生**、worker 跑**垫片** → 能跑的内核被判成不能跑 |
| 第二次 | 探测装 **1 个**、worker 装 **14 个** → **测量的是「空 surface」** |

**共同点：测试工具本身没有被测试。** 第一次修了行为，没修「测量与实现是两套东西」这个结构；第二次才把结构修掉（机器检查 + 点名缺失）。

## 52. Backoff 死胡同已闭（P15）——同时确认「缺执行者」与「契约有洞」

### 逐条对照（`spec/v1/budgets.md`，只读）

| 位置 | 原文 | 判定 |
|---|---|---|
| `:19` | `Backoff`「Upstream 429/5xx **or** no network path」 | **两个入口，一条出口边** |
| `:48` | `Running → Backoff` actions「Close admission; **start the retry schedule**」 | 动作有名字、**无 owner** → (A) |
| `:49` | `Backoff → Running` guard「**Retry-After elapsed**, network path satisfied, **one probe succeeded**」 | 三合取项，两处没 Source |
| `:64-74` | §3 signal 表 | **没有 retry scheduler、没有 probe** |
| `:72` | NWPathMonitor「satisfied → `Backoff` → `Running` **after one successful probe**」 | 与 `:49` **互相矛盾**（不提 Retry-After）→ (B) |

**(B) 第二个洞**：`onUpstreamUnavailable` 把 `isNetworkPathSatisfied` 清零（`ControllerStateMachine.kt:356`）——**网络本来没坏，那条「新的 satisfied 观察」永远不会再来**。

### 处置：只修 (A)，(B) 只报告，**guard 一个字没动**

| 新增 | 职责 |
|---|---|
| `RetryLane.kt` | 每入口一条 schedule：窗口到 → feed `RetryAfterElapsed` → **等 path satisfied** → 一次 probe → 成功才 feed `RetryProbeSucceeded(true)`；**失败不 feed**，只排下一窗口 |
| `RetryProbe.kt` | 「one probe succeeded」的 seam，默认 = §2 Actions 里唯一点名的检查（一次 lease check），不是硬编码 `true` |
| `RetryPolicy.kt` | 指数 1s×2 / 60s cap / **20% 向下抖动** / 5 次饱和（与 Swift `ModelGatewayBackoffPolicy` 同节奏） |
| `HostStateStore.kt` | `PERSIST_HOST_STATE` 的执行者（`host-state.json`，字段同 Swift `PersistedHostState`，原子替换） |

**「失败不 feed、只排下一窗口」这条设计是对的**：它保证 probe 失败不会让状态机进入一个「已满足」的假状态。

### 设备验证（同一进程）

```
12:53:16  D14 Running -> Backoff via networkPath(unsatisfied)
12:53:16  retry schedule: attempt 1 in 971 ms
12:53:17  the window elapsed; feeding RetryAfterElapsed for attempt 1
12:53:17  attempt 1 waits for a satisfied network path before the probe (the guard needs both)
12:53:24  retry probe succeeded; feeding RetryProbeSucceeded(leaseVerified=true)
12:53:24  D14 Backoff -> Running   (admission=open)
12:53:38  APP_TURN_OK … reason=completed
```

**8 秒从断网恢复到能跑回合。**

### 顺带做掉 `PERSIST_HOST_STATE`

设备证据：`boot: disposition=crash_recovery, state=Running (persisted_running)`。之前每次 boot 都是 `persistedState=null`（COLD_START）。

P15 的理由值得记：**「该持久化，而且必须——否则 §3 的 persisted 行在 Android 全部不可达」**。

### 反向验证逐个生产者

| 删掉 | 红 |
|---|---|
| `armRetry` | 4 |
| `retry.onNetworkPath` | 5 |
| `onRetryAfterElapsed` | 4 + RetryLaneTest 2 |
| `onProbeSucceeded` | 4 + RetryLaneTest 1 |
| `persistHostState` | `everyTransitionPersists` |

### ⚠️ 它暴露的两个新问题

**1. 网络抖动杀死有序通道且不自愈**（已派 P22）

> `channel closed cause=CLIENT_CLOSED` → UI「未连接」→ **不自愈**（12:47:39 那次 turn `api_aborted`）
>
> D14 状态是对的，缺的是 engine 侧重连。

**2. 进程内 engine 重启撞 mseq 水位**

> 停止/启动后 worker 仍带 mseq 87，WAL 已到 1811 → `WAL allocated mseq 1811 for the worker's 87; closing the transport` → `HANDLER_FAILED`

### 结构性结论：**六个异常状态，零个出口**

| 状态 | 入口 | 出口 |
|---|---|---|
| `Draining` | ✅ | ✅ **已修**（P10） |
| `Backoff` | ✅ | ✅ **已修**（P15） |
| 通道断开 | ✅ | 🔄 P22 |
| `PlannedRestartRequested` → `Recovering` | ❌ 无生产者 | ❌ |
| `HandingOff` / `Remote` / `Reclaiming` | ❌ 无生产者 | ❌ |
| `UpstreamUnavailable`（429） | ❌ Android 无生产者 | ❌ |

**根因不是「某处漏了」，是状态机从契约推导得很完整，但实现只接了主路径（`Running`）。** 所有异常状态的出口都停在纸面上。

**这是本轮最重要的结构性发现**，比任何单个 bug 都重要。建议把「**每个状态的出口都有执行者**」作为验收项，而不是继续逐个发现。

## 53. WAL 恢复 OOM 已闭（P19）——峰值从「2.5× 文件」降到「0.5× 文件」

### 复现：两次启动两次崩，栈完全一致

```
java.lang.OutOfMemoryError: Failed to allocate a 37748752 byte allocation
  with 25165824 free bytes and 34MB until OOM, target footprint 190719648, growth limit 201326592
    at java.lang.AbstractStringBuilder.ensureCapacityInternal
    at com.phonedsh.agentcore.JsonParser.parseString(JsonValue.kt:209)
    at com.phonedsh.log.WalJson.parse(WalJson.kt:30)
    at com.phonedsh.log.WalScanner.records(RecoveryPlan.kt:156)
    at com.phonedsh.log.WorkspaceLog.readSegment$core(WorkspaceLog.kt:792)
    at com.phonedsh.log.WorkspaceLog.recover
```

### 根因：**A+B+C+D 同时成立**（不是一个原因）

| # | 原因 | 具体 |
|---|---|---|
| **A** | 全量读入 | `readSegment` 用 `Files.readAllBytes` 整段读；`replaySegments.map { readSegment }` **把所有 segment 解成 List 并一直持有** → 9 条记录 = 120 MiB 常驻 |
| **B** | 无界 builder | `JsonParser.parseString` 为 hex 字符串建 `StringBuilder`，扩容翻倍到 36 MiB 时 OOM（**栈顶就是这里**） |
| **C** | **解析器 6× 放大** | `data_hex`（2×）→ `JsonString`（2×）→ `HexBytes.decode`（1×）；**单条记录约 6×D** |
| **D** | **记录上限缺失** | `MutationBody.MAX_DATA_BYTES = Int.MAX_VALUE` → 一条 128 MiB 记录可写进 WAL 却**永远恢复不了** |

**量化**：峰值 ≈ `Σ(已保留) + 6×D_当前`。9×15 MiB → 210 MiB（实测 OOM 时 target footprint 190 MB / heap 192 MB）。**单条 128 MiB 记录 ≈ 9×D ≈ 1.2 GiB。**

**「6×」这个数字是这份报告最有价值的一个数**：它解释了为什么「文件 128 MiB + heap 192 MiB」会 OOM——不是差一点，是**要 1.2 GiB**。

### 修法：流式 + 上限 + 诚实拒绝

| 件 | 内容 |
|---|---|
| `WalSegmentReader.kt`（新） | 按帧读 `len|crc32c|mseq|body`，**一帧一解码**，应用后立刻丢 body；复用写路径同一个 `MutationBody.decodeBody` |
| `replayInto` 流式化 | 只保留每 segment 元数据；诊断 body 全局上限 **4 MiB**；`epoch-close` **永远保留**（`HostWal` 的 `durable_mseq` 依赖它） |
| `MaterializedInvariant` 流式化 | 不再重建文件，改为逐记录按 offset 与磁盘 **64 KiB 分块比较** |
| **15 MiB 上限 + 诚实拒绝** | append 超限 → `BAD_PAYLOAD` 且**不消耗 mseq**；recovery 在**分配前**按帧长度拒 `WAL_RECORD_TOO_LARGE` |
| 补回链校验 | 新 reader 不复刻 kernel 的 mseq 链检查，所以 `WalScanner.scan` 把 kernel 的 `chain_error` 视为 corrupt |

### 超限时的行为：诚实拒绝，不是 OOM

```
WAL_RECOVERY_FAILED code=WAL_RECORD_TOO_LARGE
detail=wal/00000001.000000.xlwal is 134217859 bytes, above the 15794284-byte maximum
       of a conforming segment: one record may carry at most 15728640 data bytes (channel.md §3.1)
       … The workspace is not modified; recovery refuses it instead of running out of memory
```

**「refuses it instead of running out of memory」这句是判据**：不是「我们尽力了」，是「我们明确拒绝并说明原因」。

### 峰值内存（修复前后）

| | 修复前 | 修复后 |
|---|---|---|
| 峰值 Dalvik PSS | 165.1 MiB / heap 192 MiB → **OOM** | **61.4 MiB**（有 manifest）/ **83.4 MiB**（整段重建） |
| 峰值 TOTAL PSS | 274.6 MiB | 169.9 / 186.4 MiB（含 WebView） |
| **与 128 MiB 文件的关系** | **~2.5× 文件** | **0.48–0.65× 文件**，且**不随记录数增长** |

### 数据完好（这是关键，不是「不崩」）

```
files/xl/materialized/workspace/big.bin 由 recovery 从 WAL 重建
sha256=3e9cb1eb665a7c7432bfc09fd5f3921e60c3fa092b63a13f33373846c6b86ee1
与 host fixture 逐字节一致；manifest last_mseq=9, materialized_upto_mseq=9
```

### 一条测试设计值得记：**堆小于文件**

`RecoveryInSmallHeap.kt` 把同一个 workspace 放进 **`-Xmx128m`** 的子进程里恢复——**堆比文件本身还小**，仍然通过。

这比「峰值 PSS 61 MiB」更硬：它证明了**恢复过程的内存与文件大小无关**，而不是「这次刚好够用」。

### 反向验证：因果，不是环境差异

```
安装修复前 APK（sha256 a203d59a…）于同一 fixture → 两次启动两次 OOM（13:02:45 / 13:03:33）
重新装回修复 APK → 正常恢复
```

**同一设备、同一 fixture、只换 APK**——这排除了「环境差异」和「fixture 不同」两种解释。

### 两个契约缺口（只报告，未改 spec）

1. **`wal.md` 没有单条记录上限**：`:63` 的 `len` 是 `u32`，`:25-26` 只说 >8 MiB 的记录独占一段，全文没有上限。所以「15 MiB 拒绝」目前是**实现选择**而非契约规定。建议 §3 补一句。
2. **Android 未按 `MemoryInfo.totalMem` 选 budgets 档**：2 GB 设备（≤3 GiB 档，单文件 16 MiB）**仍能收到 128 MiB 文件**。需另一条车道在 `:dsh` 落 tier。

**第 2 条是这一系列 bug 的根源之一**：契约按内存分了档，实现没选档，于是「小内存设备收到大档文件」——P19 修好了恢复，但**档位本身还没落实**。

### 数字

```
JVM 测试  1425 / 0 failing（:core 174、:dsh 176、:lib 473）
structure 11/11 PASS
phone-android-tests / phone-android-structure → PASS
```

## 54. 「给模型一条做不到的建议」：不可完全修 + 已做降害（P21）

### 结论：phone 侧删不掉那两行

| 位置（pinned checkout `7be5505b`） | 内容 |
|---|---|
| `packages/sandbox/sandbox/src/escalation.ts:84` | `escalationHintMarker(subject)` 产生该字符串 |
| `packages/shell/tool-bash/src/index.ts:207-208` | **判据只有「是否挂了强制沙箱」**：`escalationModes = sandboxMode === undefined ? [] : ESCALATION_TARGETS`，**从不查 approval 策略** |
| `packages/shell/tool-bash/src/render.ts:45-51` | marker 与 hint **在同一分支**，所以**无法只删 hint** |
| `packages/fs/tool-fs/src/sandbox.ts:126-130` | 对 `FS_SANDBOX_DENIED` **无条件**拼两行，**连 `escalationModes` 都不看** |

三条路都不通：

| 方向 | 可行性 |
|---|---|
| (i) profile 配置 | **不可行**：没有 knob；唯一能清空的办法是不挂 confining provider，那会一并删掉 read-only 会话的强制 |
| (ii) 输出形态 | 只能「让 harness 认不出是沙箱拒绝」（`DENIAL_SIGNATURES` 置空），代价是 **marker+hint 两行一起消失**、丢结构化 `sandbox.denied`，且**对 write/edit 无效** |
| (iii) 让 DSH 认我们的 trailer | **需改 DSH → 不可行** |

### DSH 自己在同一个请求里自相矛盾

| 来源 | 说什么 |
|---|---|
| `packages/interaction/user-approval/src/index.ts:73` 的 `NEVER_SENTENCE`（runtime context） | 「**do not request sandbox escalation**」 |
| 同一请求的工具结果 | 「**escalation available — retry with sandbox_permissions**」 |

**这是上游的缺陷，不是我们的**。已记为「上游一行修复」建议：`escalationModes` 应把「能否批准」算进去（`ctx.approval` 缺失或 policy 为 `never` → `[]`），并且 `tool-fs` 的 `mapError` 应**保留 provider 的原因文本**。

### 降害：AGENTS.md 反向指令，**设备上有效**

修前 / 修后的工具结果**逐字相同**（两行装饰都在）。变的是模型行为：

> 模型引用 marker 并说明「`/dsh/config` is read-only in every mode … the mentioned `sandbox_permissions` escalation **is not an option — retrying would be rejected automatically**」，随后建议改 `/dsh/workspace`，**没有重试**。

**这是能拿到的最好结果**：删不掉那条建议，但可以**教会模型忽略它**。

### 顺带发现一个更糟的 bug（已派 P24）

`write` / `edit` 被拒时，模型收到的**完整**结果是：

```
Error: [sandbox: file access denied under workspace-write mode]
[sandbox: escalation available — retry this exact operation once with sandbox_permissions …]
```

**零诊断**——没有路径、没有原因、没有可行动建议。根因是 `tool-fs/src/sandbox.ts:126-130` 的 `mapError` **把 provider 的原因文本整段换掉了**。

**对比 bash 侧**（同一时刻）：

```
EACCES: permission denied, open '/dsh/config/x'
pdsh-shell: writable roots are /dsh/workspace, /dsh/home, /tmp, /dsh/tmp, /dev/null
```

**同一个策略，bash 有三行有用信息，fs 有零行。** 这是「一个策略多套渲染」的第五个实例。

### 顺带发现一处静默截断

`AGENTS_MD_MAX_BYTES` 原为 4096，而**真实设备文档本来就超了**——`clampMarkdown` 正在**静默丢弃** `Bash deviations` / `Restart and recovery` / `Manifest` 三段。

P21 把 cap 抬到 5120 并加了「不得截断、≤ cap」的断言。**但抬 cap 只是把问题推后**：真正的缺陷是**静默**。已让 P24 一并查 `clampMarkdown` 是否应改成**显式**（打印被丢的段落名）。

### 一条方法论：这个答案是「合格」的形状

任务允许「做不到就如实说」。P21 交的正是这个形状：

> **不可完全修**（附代码位置与三条路各自为何不通）+ **已做可落地的降害**（附设备证据）+ **上游修复建议**（一行 + 契约措辞）

**比「声称修好了」有价值得多。**

## 55. shell 侧列表不可见（P20）——§45 裁定完成

### 最主要的泄漏途径不是 `ls`，是 glob

修复前实测：

| 命令 | 修复前 |
|---|---|
| `ls /dsh/home` | `AGENTS.md capabilities.json notes sessions storages tool-journal`，**exit 0** |
| **`echo /dsh/home/*`** | **glob 展开直接列出三名**（P20 标注「最重要」） |
| `find /dsh/home -maxdepth 1` | 三名都出现，**无 EACCES**（不下降就不触发守卫） |
| `tree` / `du -a` | 三名 + 3 行 EACCES |
| `ls /dsh/home/../../home` | 三名照列（路径折叠后同样） |

**`echo /dsh/home/*` 那条最要命**：它不需要任何特殊命令，bash 的 glob 展开就会把三个内部根的名字交出去。

### 修法：一条规则 + 两个落点

| 件 | 内容 |
|---|---|
| 规则 | `VfsNamespace.execEntryVisible(directory, name)`——**与 `execReadable` 刻意独立** |
| 落点 1 | `wrapFsPromises` 的 `readdir`（`installExecFsPolicy` 打到 Worker `node:fs.promises` 的那个面；shell、`git`、WASI live `python3` 都读它） |
| 落点 2 | `VfsFileSystem.readdir`/`readdirWithFileTypes`/`getAllPaths`（shell 唯一 `IFileSystem`，**glob 引擎也走这里**） |

**「与 `execReadable` 刻意独立」这个设计判断是对的**——否则反向验证 #2 就不成立（删访问守卫会连带删过滤，两个性质分不开）。

### 两条反向验证互相独立（正是我要求的）

| 去掉 | 结果 |
|---|---|
| 过滤（`execEntryVisible` return true） | `not ok 1`（`ls leaked sessions`）+ `not ok 2`，**`ok 3`（访问仍 EACCES）绿** |
| 访问守卫（`assertExecReadable` no-op） | `not ok 3`（`Missing expected rejection`），**`ok 1`/`ok 2`（列表仍隐藏）绿** |

### 设备验证（emulator-5584）

```
ls /dsh/home            → AGENTS.md capabilities.json cordis.patch.yml profiles
ls -la /dsh/home        → 仅 5 个可见项
find /dsh/home          → 仅 4 项
find /dsh/home -maxdepth 1 → 同上
tree /dsh/home          → 2 directories, 5 files
du -s /dsh/home         → 72
echo /dsh/home/*        → AGENTS.md … profiles   ← glob 不再泄漏
```

显式访问（storages/tool-journal）仍 **EACCES + remediation**。

### 一处需要说清的观察（不是缺陷）

新 AVD 上 `/dsh/home/sessions` **本就不存在**（该镜像的 DSH session lane 不写这个根），所以 `stat` 给的是**真 ENOENT**——这是对的，不是 bug。

P20 还做了个漂亮的对照：先 `mkdir /dsh/home/sessions` 再 `stat` → **EACCES**；再次 `mkdir` → `File exists`（**证明存在但被隐藏**）。

### 它提出的契约补句（我认可，转 spec owner）

> A directory listing of an execution surface never names those roots: a `readdir` of `/dsh/home` omits them, so `ls`, `find`, `du`, `tree`, completion and glob expansion cannot discover them. A path that names one of the roots directly — or a descendant of one — still answers `EACCES` with the remediation line above, never `ENOENT`; **invisibility is not absence**.

**「invisibility is not absence」** —— 这七个词把整条裁定压缩完了。

### 遗留（P20 报的，非本次范围）

| 项 | 说明 |
|---|---|
| `opendir`（Dir handle）未按名过滤 | 目前唯一消费者是 fork 捕获，它自己跳过内部根；建议补 |
| `cat` 对**不存在**的内部子路径给 ENOENT | 既有行为（open 先查存在性），与过滤无关 |
| 内部根的**写入不持久** | P12 宿主的既有语义，建议单开一条 |

## 56. budgets 档位落实（P23）+ 一处契约内部矛盾

### 档位表（首次按物理内存选档）

选档规则（`budgets.md:95-97`）：每次 boot 按 `MemoryInfo.totalMem` 选一次；8 GiB 行是默认。

| 行 | 阈值 | **Single file** |
|---|---|---|
| 12 GiB | ≥12 GiB | 256 MiB |
| **8 GiB（默认）** | [8,12) | **128 MiB** |
| 6 GiB | [6,8) | 48 MiB |
| 4 GiB | [4,6) | 32 MiB |
| ≤3 GiB | <4 GiB | 16 MiB |

### `VFS_REFUSED` 还是 `EFBIG`？**两个都对，不同层**

| 层 | 条款 | 行为 |
|---|---|---|
| **工具层**（用户看到的） | `channel.md:264-268` | Worker VFS 超限 → **`EFBIG`**，且**不发 `VFS_MUT`** |
| **wire 层**（host 预算拒绝） | `channel.md:236` + `:298` + `:362` | 一条 `ERROR VFS_REFUSED`（path/limit/reason + `accepted_bytes`），**不吃 mseq、不关连接、不进 Failed** |

**两层都实现了。** 这个区分很重要——之前 P13 修 EFBIG 时只修了工具层，host 侧的 `VFS_REFUSED` 兜底是这一轮补的。

### 通告方式：worker env，不是 HELLO caps

`PDSH_SINGLE_FILE_LIMIT_BYTES` 走 `pageParams["env"]`。理由：
- `channel.md` §4.1 HELLO **没有该成员**
- caps 明确「Other capability strings are reserved」
- 而 `plugins/wasi-toolbox/src/limits.ts:43-44` **本来就把这个 env 定义为「host 发布 single_file_limit 的通道」**

**「按既有约定扩展」而不是「新增协议字段」——这个选择对。**

### 设备实测：档位真的生效了

| AVD | `MemTotal` | 档位 | `single_file_limit` |
|---|---|---|---|
| 5590 (2 GB) | 2,592,759,808 | **≤3 GiB** | **16,777,216（16 MiB）** |
| 5592 (6 GB) | 6,214,840,320 | **4 GiB** | **33,554,432（32 MiB）** |

6 GB AVD 实测 **5.79 GiB** → 落在 4 GiB 行，这是 `:95-96` 的语义，**不是偏差**。

### 核心验收：2 GB 设备上超档写入被拒

```
append_1 … append_16 exit=0
-rw-r--r-- 1 user user 16777216 /dsh/workspace/p23-big.bin
[stderr]
EFBIG: File too large: … would be 17825792 bytes; a file is limited to 16777216 bytes (16 MiB)
```

**文件停在 16,777,216 B，不是「写进去再恢复失败」。** 而且 `16 MiB` 由 `formatByteLimit` 渲染，证明 **worker 用的是 host 发布值**（内置默认是 128 MiB）。

**A/B 对照**：同一操作在 32 MiB 档的 5592 上 20 MiB **全部成功**（无 stderr）。

### 反向验证

把 `forTotalMemory` 改成 `forTier(GIB_12)` → `HostBudgetTierTest` **6 tests completed, 6 failed**；还原后 BUILD SUCCESSFUL（`--rerun-tasks` 复跑）。

### ⚠️ 它查出一处**契约内部矛盾**

`channel.md:264`：

> One file is at most the host's `single_file_limit`: the budgets.md tier default (**64 / 48 / 32 / 16 MiB**) …

而 `budgets.md:104` 是 **256 / 128 / 48 / 32 / 16**（五行）。

| | 值的个数 | 8 GiB 默认行的值 |
|---|---|---|
| `budgets.md:104` | **5** | **128 MiB** |
| `channel.md:264` | **4** | 缺；最大只到 **64 MiB** |

**两处 spec 对同一个安全相关的限值说法不一致，而且错的是 `channel.md`——它是 wire 契约。**

后果：**一个照 `channel.md` 实现的客户端会以为默认是 64 MiB，实际是 128 MiB**——差 2 倍。我们按 `budgets.md` 实现（它才是 budgets 的 owner），但这个矛盾必须由 spec owner 修。

### 它没做的一件（判断对）

只发布了 `single_file_limit`；`PDSH_VFS_LOGICAL_BYTES` / `WORKSPACE` / `SESSIONS` / `TMP` / `WASI_HOT_INSTANCE_BYTES` 都**没接**，因为 host 侧没有对应的 VFS 总量 `ENOSPC` 实现。

**避免「半接线预算」是对的**：发布一个 host 不执行的限值，比不发布更糟（worker 会以为被保护）。

### 数字

```
1448 tests / 0 failing（:dsh 187）
structure_check 11/11
```

## 57. 「未测量时用哪一档」：契约没规定，取安全侧（P23 返工）

### 契约确实没写

`budgets.md:95-97`：

> Device tiers are selected once per boot from the physical memory ceiling. The 8 GB row is **the default**; a lower row applies when the ceiling is below 8 GiB …

**「the default」指的是「按上限选档时的基线」，不是「未知时的兜底」。** 验证：`grep -ic "unknown" spec/v1/budgets.md` = **0**，全文没有 "unknown"/"unmeasured"，也没有「读不到时用哪一档」的条款。

**所以取安全侧是正当的**，而不是违背契约。

### 修法：删掉 `DEFAULT`，换成 `UNMEASURED`

```kotlin
// 删掉：HostBudgetTier.DEFAULT（8 GiB 行）
HostBudgetTier.UNMEASURED = ControllerBudgets.forTier(MemoryTier.AT_MOST_3)  // 16 MiB
```

三处默认值统一指向它：`HostBudgetTier` / `PhoneDshHost.deviceBudgets` / `VfsSink.singleFileLimitBytes`。

**理由（它自己写的，我认可）**：「从未测量」和「读到 0」是**同一个事实**，不能有两个答案。而且**猜低只是让设备少拿配额；猜高正是本车道要修的病**。

### 两条反向验证把两个性质分开了

| 改回什么 | 红 |
|---|---|
| `UNMEASURED` 改回 8 GiB 行 | **2 条**（常量那条 + 端到端那条） |
| **只**把 `PhoneDshHost` 构造函数默认值改回 8 GiB（常量仍是 16 MiB） | **1 条**（只有端到端那条） |

**第二条是这份返工里最关键的设计**：它证明端到端测试钉的是**构造函数默认值本身**，而不只是那个常量。**如果默认值和常量能各自漂移，只测常量是不够的。**

### KDoc 里那段证据等级声明，是全项目该抄的范本

> `---- evidence level: JVM only, no device capture ----`
>
> There is **no device-level evidence** for this branch. On a real device the Worker refuses first (`EFBIG`) … a device can only reach this backstop if that environment is dropped or ignored … **Do not read the device run (2 GiB AVD: `EFBIG … limited to 16777216 bytes`) as proof that this branch fired.**

**「不要把那条设备记录当成这条分支生效的证明」** —— 这是防止未来的人误读证据的写法，比「本分支有测试覆盖」强得多。

### 数字

```
1450 tests / 0 failing（:dsh 189）
phone-android-structure + phone-android-tests → PASS
```

## 58. fs 拒绝零诊断已修（P24）——并挖出一处**能力层面**的不一致

### 根因：我们的诊断根本没被走到

| 步骤 | 事实 |
|---|---|
| **产生** | **DSH 的 `fs-sandbox`**（不是我们的 provider）：`packages/fs/fs-sandbox/src/index.ts:127/141` 的 `checkedTarget()`，**消息里本来有路径** |
| **丢失** | `packages/fs/tool-fs/src/sandbox.ts:124-130` 的 `mapError()` 对 `FS_SANDBOX_DENIED` **无条件整段替换** message，原文只留在 `cause` |
| **救不回来** | `packages/core/tools/src/index.ts:1917` 的 `toolErrorResult()` 只取 `Error: ${errorMessage(error)}`，**cause 链在进入 tool result 前就被丢弃** |

**最关键的发现**：`write`/`edit` **先撞 `fs-sandbox`**，我们自己的 VFS fence（`writeDenial`，即 bash 那句 `EACCES …` + roots）**根本没被走到**。

### 修法：追加第二个 block，不替换任何东西

phone-owned Cordis plugin `pdsh-fs-denial-diagnostics`，挂在 `tools/post-execute` waterfall，用既有 app-boot shim 缝 mount（**不需要 profile 行、不改 DSH**）。

触发条件严格：`isError` + `error.info.code === 'FS_SANDBOX_DENIED'` + 工具名 ∈ {write, edit}；写成功、其它错误码、bash、下游 `block`、已追加过的一律原样返回（幂等）。

### 三分支——因为**两道 fence 不是同一道**

| 路径 | 诊断 |
|---|---|
| `/`、`/dsh/config/**`、`/dsh/bin/**` | 「outside the phone's writable roots，`write`/`edit`/`bash` **都拒**（image 任何模式下只读）」 |
| **`/dsh/home`**、`/dev/null` | **「`/dsh/home` is writable from `bash`, not from `write`/`edit`」**——因为 fence 不同 |
| read-only 会话 | 单独一条 |

**`/dsh/home` 那条必须说实话**，否则「可写根里有 `/dsh/home`」与「被拒」自相矛盾。它没选择屏蔽这个矛盾，而是**把它写进诊断**。

可写根那句**逐字复用** bash 的 `writableRootsLine()`，单测里硬编码比对防第三种措辞。

### 修后设备原文

```
# /dsh/config/x
pdsh-fs: cannot write "/dsh/config/x": the path is outside the phone's writable roots,
  so `write`, `edit` and `bash` all refuse it (the image is read-only in every mode).
pdsh-shell: writable roots are /dsh/workspace, /dsh/home, /tmp, /dsh/tmp, /dev/null (TMPDIR=/dsh/tmp)
next: retry with a path under one of those roots … `sandbox_permissions` cannot widen an image path
  and this deployment has no approval prompt, so escalation is always refused.

# /dsh/home/x
pdsh-fs: cannot write "/dsh/home/x": "/dsh/home" is writable from `bash`, not from `write`/`edit`
  — this tool is fenced at the workspace root and the temp roots.
pdsh-shell: writable roots are …
next: write it with `bash` (for example `printf … > "/dsh/home/x"`), or put the file under
  "/dsh/workspace" and retry `write`/`edit` there.
```

**路径 ✓、可写根（与 bash 同句）✓、可行动建议 ✓**，并**当场否掉那条永远无法兑现的提权提示**。

### 真模型闭环（真 key，非脚本）

```
[CALL] write {"file_path":"/dsh/config/p24-real.txt"}      → isError
[ASSISTANT] That path is in the read-only image. I'll place the file under the writable workspace instead.
[CALL] write {"file_path":"/dsh/workspace/p24-real.txt"}   → 成功
```

设备上 `files/xl/materialized/workspace/p24-real.txt` 内容 `hello-p24`，`/dsh/config/p24-real.txt` 不存在，**没有**去试 `sandbox_permissions`。

### `clampMarkdown`：从「半静默」改为「显式」

之前只说 `(The summary was shortened to fit N B …)` ——**不说丢了什么、几段**。

现在：

```
[truncated to 4200 B: dropped 3 sections: Bash deviations (ENG-02 expected deviations),
 Restart and recovery, Manifest; part of "Paths and /tmp";
 the machine-readable lists are in /dsh/home/capabilities.json]
```

**计数 + 段名 + 被切一半的段名 + 精确清单指针。**

### ⚠️ 它挖出的能力层面不一致（我裁定不改，但要写进契约）

| fence | 可写路径 |
|---|---|
| **`bash`**（VFS 根表） | `/dsh/workspace`、**`/dsh/home`**、`/tmp`、`/dsh/tmp`、**`/dev/null`** |
| **`write`/`edit`**（`dsh-sandbox` 的 `writableRoots`） | `[workspaceRoot, /tmp, tmpdir()]` |

**差集 = `/dsh/home`、`/dev/null`：bash 能写，`write`/`edit` 不能。**

这是「一个策略多套渲染」的**能力版**——不只是措辞不同，是**允许的动作不同**。P24 选择**如实告诉模型**而不是掩盖，这是对的。

**契约层面需要 spec owner 定**：两个 fence 是否本该相同；若不同，`channel.md` 该怎么表述。

### 数字

```
新增 fs-denial-diagnostics.test.ts(10) + capabilities-truncation.test.ts(7) → 17/17
反向验证：改回直接 return decision + 旧 generic 后缀 → 5 条红
```

## 59. 两个写面、两套集合（P24 返工）+ 我抬了 cap

### 契约建议：**A 是权威，A_tool 是文档化的子集**（不统一）

| 集合 | 内容 | 问题 |
|---|---|---|
| **A**（VFS 根表，`channel.md:259-261`） | `/dsh/workspace`、`/dsh/home`、`/tmp`、`/dsh/tmp`、`/dev/null` | 「哪些路径能被**执行面**（bash/python3/git）写」 |
| **A_tool**（`sandbox/src/roots.ts:52-55`，经 `fs-sandbox`） | `{workspaceRoot} ∪ {/tmp, tmpdir()}` = `/dsh/workspace`、`/tmp`、`/dsh/tmp` | 「DSH **进程内**工具（write/edit）能改哪里」 |

**关系：`A_tool ⊊ A`，差集恰是 `/dsh/home`、`/dev/null`。**

**契约从没说过 write/edit 比根表窄**——所以「channel.md 说可写」与「write 说被拒」两句话都成立。**这是契约缺口，不是实现 bug。**

P24 的建议措辞（我认可，转 spec owner）：

> **Two write surfaces, two sets.** … `A_tool ⊆ A` in every mode; a deployment may narrow it, **never widen it**. A refusal from either surface names (1) the refused path, (2) the set that applied, (3) the surface that can perform the write. Both surfaces share **one** writable-roots sentence … `sandbox_permissions` widens neither on a device with no approval channel.

并建议写成跨树**不变量**（`no execution surface may write outside A; no in-process fs tool may write outside A_tool`），交给 `cross_check.py` 钉住。

**为什么倾向「分级」而不是「统一」**：

| 方向 | 代价 |
|---|---|
| 向上统一（write/edit 也能写 `/dsh/home`） | 把**模型受控路径**的写面扩大到 `$HOME`（AGENTS.md、sessions、git config、tool-journal 都在那儿），越过 sandbox 的单 workspaceRoot 模型，需上游多 root |
| 向下统一（`/dsh/home` 从 A 删掉） | 直接打断 `$HOME` 语义（DSH 自己要往那写 AGENTS.md/sessions） |

**真统一要走上游多 root 策略，不是 phone 侧补丁。**

### `FS_NOT_FOUND` / `FS_NOT_OBSERVED` 也贴诊断了——而且**做了判断，不是机械复制**

| 要点 | 做法 |
|---|---|
| 只有 `FS_SANDBOX_DENIED` 带 harness 提权 hint | 所以**只有它**复述「提权不可能」；另两码的文案用 `doesNotMatch(/sandbox_permissions\|escalat/)` 钉住**不出现** |
| `FS_NOT_OBSERVED` 的 provider 文案说「read the file, then retry」 | 在受禁路径上**这是陷阱** → 改为「reading it first does not help — the path stays unwritable after the read」 |
| 两码的文本没有 harness marker | mode 改从 session policy 取（`markerMode ?? fence.mode ?? 'workspace-write'`） |

**反向验证 B 是这次最有价值的测试**：保留三码但把 `missingTarget` 换成**机械复用** `sandboxDenial` → **4 红**。

**它钉的不是「有没有贴诊断」，是「有没有做判断」。**

### 一处**自我测量更正**

> 上一轮报的「设备 AGENTS.md = 5055 B、余量 65 B」是 **compact 形态**，不是全文。抬到 6144 后同一设备实测 **5538 B**。

所以：5055 B 时 `markdownFor(document, true)` 的 compact 回退**已经悄悄生效**（命令表被折成 count+8 例）；4 KiB 时代是 compact 之后仍超，才由 clamp 丢段。

**真实余量 = 6144 − 5538 = 606 B**，不是我估的 ~1.1 KiB。

**我据此重裁：cap 抬到 7168**（≈1.6 KiB 余量），已改并验证：

```
tsc → clean
capabilities-truncation.test.ts → 8/8 pass
```

**不改「显式截断」逻辑**——抬 cap 只是买时间，溢出仍然要可见。

### 它查实的 `:app` 缺陷（已派 P25）

`ProbeLaunchConfig.workerEnvironment()` 把 `DEEPSEEK_API_KEY` 占位符与 `PDSH_MODEL_KEY_STATE` **整块嵌在 `if (base != null)` 里**，而同一方法的 KDoc 写着「leaves DEEPSEEK_API_KEY at the placeholder **for every state**」。

**实现与自己的 KDoc 矛盾。** 后果：

- Worker/页面**分不出「未配置」与「已配置」**——而这正是 `PDSH_MODEL_KEY_STATE` 存在的理由
- 实测症状：`llm-deepseek: no API key for provider route "deepseek-official"`，但真实原因是 **baseUrl 没传**
- **诊断信息指向错误方向**：模型会去查 key，而问题是 baseUrl

**这是「把未知折成已知」的又一例**：把「不知道 key 状态」折成了「没有 key」。

### 一条跑法必须写下来（已写进 README）

```
--es pdsh.deepseek.baseUrl https://api.deepseek.com/anthropic
+ files/import-key.txt 种子
```

**不传 baseUrl 就连 key 占位符都不给**——下一个人会以为「不传也能跑」，然后卡在 `no API key`。

## 60. 通道自愈（P22）——最后一个 🔴 关闭，但**触发器仍在**（已派 P26）

### 根因：「没人重开」+ 通道是**被 worker 自己关的**

| 层 | 事实 |
|---|---|
| **触发器** | `VfsSink.onMut` 在 admission 关闭时回 `VFS_RESYNC`，**不 append、不 ACK**；bundled worker 对该帧**只 decode 后 return** → Backoff 期间**烧掉 480 个 mseq**（105→585） |
| **为什么烧** | admission 一开，下一帧必然 `BAD_MSEQ: expected 105, got 585` |
| **页面客户端** | **有**重连循环（100 ms→5 s 退避），但 `BAD_MSEQ`/`RING_TIMEOUT` 属 `protocolFailure` → 置 `fatalError` → **永久不重连** |
| **宿主/engine** | `HostChannel.onClosed` 只清理；`Running→Recovering→Running` **只接了 onRenderProcessGone** → 通道一断，进程剩余生命周期全死 |

### 修法：只用既有边

新增 `:engine/ChannelReopenLane`：

```
Running → Recovering（lifecycle.markRecovering()，与渲染进程死亡同一条边）
  → 4 s 首个窗口（先让页面自己重连；实测 worker 懒激活关通道后 1.2 s 自愈）
  → 宿主 admission 关闭时「只等不重载」
  → loadUrl 同一页（不新建 WebView）
  → 通道真的回来后 onChannelOpened 才 Recovering → Running
```

退避 **4/8/15 s 封顶**，30 s 内最多 3 次重载；通道 20 s 内再掉线则继续升。

### 设备实测发现**两种新变体**，都覆盖了

| 变体 | 现象 | 修法 |
|---|---|---|
| **僵尸通道** | close 从没被 origin 看到 → engine 仍 `connected=true`、origin 单槽被占 → 页面每次重连吃 **409**、`/api` 全超时 | `watchStaleChannel`（`channelsRejected` 相对基线增长 + `StaleChannelRule`）走同一 episode |
| **槽位卡死** | 重载也拿不到通道（槽位仍被占） | lane 升级为 `stop()+start()`（同一 D14 行的 `RESTART_WORKER`） |

### 设备验证（同一进程）

```
13:45:55  channel channel-1: closed cause=TRANSPORT_LOST (live=0)
13:45:55  ordered channel lost: Running -> Recovering (the page will be reloaded once the host accepts writes)
13:45:55  E APP_TURN_FAILED reason=channel_lost          ← 新码，不是含糊的 api_aborted
13:45:56  channel reopen: reloading the page (attempt 1)
13:45:56  channel channel-2: open (live=1)
13:45:56  recovered: … after 1 reload attempt(s)
13:46:35  APP_TURN_OK … reason=completed
```

僵尸通道（靠看门狗救回）：

```
13:47:18  E stale ordered channel: the page asked for a new upgrade and the origin refused it
            (channelsRejected=2, channelsAccepted=2) while this engine still believes it is connected
13:47:19  channel channel-3: open (live=1)  →  recovered
13:47:58  APP_TURN_OK
```

### 上界证据（不退避会风暴）

| 观测 | 结果 |
|---|---|
| `attemptsWithin(30_000)` | **3**（4+8+15 s，单测钉住） |
| 断网 20 s 期间重载次数 | **0**（admission 关闭 → 只等） |
| 恢复后重载次数 | **1** |
| 抖动中第二次掉线 | 升到 `attempt 2 / 8000 ms` |

### 非静默（这是 P22 做得好的地方）

- 每步都有日志
- `ChannelTelemetry` 对 `CLIENT_CLOSED` 也留 `lastError`
- UI 的 Recovering 文案覆盖两种原因
- `:dsh` 把「连接在请求下面断掉」从含糊的 `api_aborted` 改成新码 **`channel_lost`**，并记录被带走的在途请求数
- `session/create` 的 1 Hz×180 次改成 250 ms→2 s 退避（30 s 内 17 次，单测钉住）

### 反向验证：5 个入口逐个删

| 删掉 | 红 |
|---|---|
| `onClosed` 里的 `onChannelLost?.invoke(cause)` | `reportsTheOpenAndTheCloseOfALiveConnectionExactlyOnce` |
| lane 的 `onEpisodeStart()` | `aLostChannelIsReopenedByReloadingThePage` |
| lane 的 `reload(attempts)` | 5 条 lane 测试 |
| `hostAcceptsWrites()` 闸门 | `noPageIsReloadedWhileTheHostRefusesWrites` |
| `StaleChannelRule.isStale` 恒 false | `aRefusedUpgradeWhileConnectedMeansTheChannelIsStale` |

### ⚠️ 它自己指出：**触发器还在**

P22 明确写了：

> `VfsSink` 的「admission 关闭 → RESYNC 不 append/不 ACK」是**触发器**

**自愈能救回来，但每次断网都会再来一遍，而且那一轮必然失败。** 已派 **P26** 修那个，并要求先核实契约语义（§3.4 的 RESYNC 到底要求 worker 做什么）。

### 它还留了一条**内容一致性**的疑虑（重要）

> 重载后 worker 的 VFS 内存视图从镜像重建，而 WAL 已前进，mseq 连续但**内容一致性没有对账证据**

**已让 P26 判断**这是真风险还是过度担心。如果是真的，那是自愈机制的一个隐藏代价：**通道恢复了，但内存视图可能不是最新的**。

### 诚实记录：设备退化

> 同一 AVD 跑 ~40 次切换后 WebView 网络栈退化——每次页面载入 1–2 s 内通道自己 TRANSPORT_LOST。lane 每次都能救回，但那一轮 turn 必然被打断。

**§5 的两次 `APP_TURN_OK` 是在退化之前取得的。** 这个标注很重要——否则读者会以为 40 次切换后仍然完好。

### 数字

```
1453 tests / 0 failing（:engine 92、:dsh 189）
structure_check 11/11
```

### 三个待定（P22 报的）

| # | 问题 | 归属 |
|---|---|---|
| 1 | `VfsSink` 的 RESYNC 语义 vs bundled worker 实现不符 | **P26** |
| 2 | `:net` 没有「关掉当前通道」的 API（只有 `stop()`），槽位卡死时只能整机重启 | 建议加 `closeChannel()` 或槽位超时 |
| 3 | D14 没有「有序通道死亡」这一行；断连期间 D14 仍 `Running/admission open`，只有 engine 的 Recovering 在说真话 | spec owner |

## 61. key 状态被 baseUrl 吞掉（P25）+ 一个**发布但无人读**的契约

### 复现（修复前，真设备）

不传 `pdsh.deepseek.baseUrl`，解出 boot.js **实际消费**的 env（从 `performance.getEntriesByType('navigation')[0].name` 取，因为 `boot.js` 读完就 `history.replaceState` 抹掉了传输参数）：

```json
{"PDSH_SINGLE_FILE_LIMIT_BYTES":"16777216","PDSH_DSH_LAUNCH_TOKEN":"<64 hex>"}
```

**key 成员全不在，env 本身存在**——这印证了另一条车道的自我更正（不是 `return null`）。

logcat：

```
D/PDSHEngine: console WARNING: … Error: llm-deepseek: no API key for provider route "deepseek-official";
              store DEEPSEEK_API_KEY through the credentials service …
E/PDSHAppTurn: APP_TURN_FAILED reason=incomplete: … reason=error
```

**报错指向 key，而真实原因是 baseUrl 没传。**

### 修法：key 事实与端点事实分开

| 成员 | 现在 |
|---|---|
| `DEEPSEEK_API_KEY`（占位符）、`PDSH_MODEL_KEY_STATE` | **提到 `if (base != null)` 外**——key 状态是设备 key store 的事实，与端点无关 |
| `DEEPSEEK_BASE_URL`、`PDSH_MODEL_NAME`、`DSH_TELEMETRY_DISABLED` | 留在门里（端点三成员只有 launch 真给了 base 才是真命题） |

**顺带修了同文件头部的第二处自相矛盾**：原注释称「valid ⇒ 真 key 进 env；absent ⇒ 连 placeholder 都没有」，与实现（三态恒 placeholder）和方法 KDoc 都相反。

### 反向验证

把 key 块嵌回 `if (base != null)`：

```
Finished 13 tests … BUILD FAILED
org.json.JSONException: No value for DEEPSEEK_API_KEY
```

**11 个旧用例全绿**——证明既有测试确实对无 base 形态是**盲区**（全部构造带 base 的 config）。

### 设备验证（修复后）

```json
{"DEEPSEEK_API_KEY":"phone-host-injects-mcp-key","PDSH_MODEL_KEY_STATE":"configured",
 "PDSH_SINGLE_FILE_LIMIT_BYTES":"16777216","PDSH_DSH_LAUNCH_TOKEN":"<64 hex>"}
```

删掉设备 key 后同一路径 → `PDSH_MODEL_KEY_STATE=absent`，其余成员不变。

带 baseUrl 回归：7 成员，真回合 `APP_TURN_OK … reason=completed`。

### ⚠️ 它如实报了一个副作用（已派 P27）

修复后无 baseUrl 的回合**不再是本地快速失败，而是发真实外网请求**：

```
W/PDSHEngine: subresource HTTP 401 () for https://api.deepseek.com/anthropic/v1/messages
D/PDSHEngine: console WARNING: … Authentication Fails, Your api key: ****-key is invalid
E/PDSHAppTurn: APP_TURN_FAILED
```

**误配置产生了外网流量，并把占位符当凭据发给第三方。**

**我的裁定：必须修。** 三条理由：
1. 没配好的设备不该向第三方发包（网络卫生）
2. 占位符被当凭据发出去，可能被上游记为攻击/限流/风控
3. **报错形状仍指向 key**（`****-key is invalid`），而真实原因是「宿主没挂 model edge」——**把「没有模型路由」折成了「凭据无效」**

已派 P27，核心验收是**零外网流量**。

### 它查实的一条：`PDSH_MODEL_KEY_STATE` **没有消费者**

> 全仓库 grep，`PDSH_MODEL_KEY_STATE` 没有任何消费者——只有 Android 生产方、engine 透传契约测试和文档。
>
> 「页面/Worker 能区分」目前是**已发布但未读取的契约**。

**这是「已实现、待接线」家族的第六个实例**（前五个：11 个未接路由的页面、`ChatRow.Context`、入站附件、sessions facts adapter、`IngressQueue`/`BackgroundExecutionFacts`）。

**「发布但无人读」和「没实现」在效果上一样，但危害更大**——因为它会让下一个人以为这条链路是通的。

### 数字

```
connectedDebugAndroidTest  27/27（ApiKeyStore 13 + ProbeLaunchConfig 13 + SessionsHostWiring 1）
KeyMaterialLoggingTest     3/3（钉住本文件不得有 logging 调用）
structure_check            11/11
```


## 62. 「没有模型路由」被折成「凭据无效」（P27）——误配置现在**零外网流量**

§61 结尾如实报的副作用：P25 让 key 状态诚实发布之后，不传 `pdsh.deepseek.baseUrl` 的回合**不再是本地快速失败**，而是把占位符 `phone-host-injects-mcp-key` 当凭据发到 `https://api.deepseek.com/anthropic/v1/messages`，拿到 401，报错却说 key 无效。本节是它的修复。

### 链路：为什么没 baseUrl 就没 edge，以及谁回落到了公开端点

| # | 位置 | 事实 |
|---|---|---|
| 1 | `ProbeLaunchConfig.kt:186-191` | `modelCredentialProvider()` 在 `deepseekBaseUrl == null` 时直接 `return null` |
| 2 | `ProbeEngineViewModel.kt:173-189` | `modelProxy` 只在 `base != null && provider != null && modelProxy` 时非空；三者缺一即 **不挂 model edge** |
| 3 | `ProbeLaunchConfig.kt:161-164` | 端点的三个成员（`DEEPSEEK_BASE_URL`/`PDSH_MODEL_NAME`/`DSH_TELEMETRY_DISABLED`）被 `if (base != null)` 挡住 → Worker env 里**没有** `DEEPSEEK_BASE_URL` |
| 4 | `WebViewEngine.kt:678-682` | 只有挂了 edge，engine 才把 `DEEPSEEK_BASE_URL` 改写成 loopback origin；没挂就**什么都不写** |

**回落是 DSH 的，不是我们的**：pinned checkout `packages/llm/llm-deepseek/src/config.ts:300`

```ts
const baseURL = config.baseURL ?? environment?.get(BASE_URL_ENV)?.value ?? PUBLIC_BASE_URL
```

`PUBLIC_BASE_URL = 'https://api.deepseek.com/anthropic'`（同文件 :115）。手机 profile 的 `llm-deepseek` 行没有 `baseURL` 配置，所以「env 里没有 `DEEPSEEK_BASE_URL`」= 官方端点。而 `adapter.ts:138` 直接调全局 `fetch`，于是 WebKit 真发了请求。

**关键的结构性事实**：这里的「缺失」在 Worker 侧是**二义的**——挂了 edge 时 engine 也会在页参数里省掉 `DEEPSEEK_BASE_URL`（它随后注入 loopback origin）。所以 Worker 无法从「没有 base URL」推断「没有路由」，只能由宿主显式说。

占位符的单一来源：`android/net/.../GatewayHeaderPolicy.kt:20`（`HOST_MANAGED_PLACEHOLDER`）→ `ProbeLaunchConfig.kt:257`（`WORKER_KEY_PLACEHOLDER`）；同一字面值也在 `Sources/PhoneDSHGateway/ModelGateway.swift:1035` 与 `plugins/phone-mcp/src/schema.ts:33`。

### 修法：宿主显式发布路由 + Worker 在网络边界拒绝

1. **宿主发布路由事实**（`android/dsh/src/main/kotlin/com/phonedsh/dsh/host/ModelRoute.kt`，新文件）：`ModelRouteFact.forLaunch(baseUrl, proxyRequested, credentialAvailable)` → `host-edge` / `direct` / `none`，`none` 必带缺失码（`base-url` / `api-key-store`）。两个成员进 env：`PDSH_MODEL_ROUTE`（恒有）与 `PDSH_MODEL_ROUTE_MISSING`（仅 none）。**没说端点、没说 key**，可以安全落日志。
   - `ProbeEngineViewModel.kt:231-232` 计算一次；`:250-261` 在 `ProbeLaunchConfig.workerEnvironment()` 的结果上追加这两个成员（**没有改 P25 的那份文件**）；`:717` 打一行 `model route: …`。
2. **Worker 拒绝**（`plugins/worker-entry/src/model-route.ts`，新文件；`entry.ts` 在 `host.start()` 之后装）：`PDSH_MODEL_ROUTE=none` 时包住 `globalThis.fetch`，凡是 Messages/Files 协议路径（`/v1/messages`、`/v1/files…`）的请求**在调用真实 fetch 之前**返回本地 `400 {error:{type:"invalid_request_error", message}}`。选择在 `host.start()` 之后安装，是因为 `llm-bridge` 会在插件激活时替换 `globalThis.fetch`；装在它前面等于包了一个马上被丢掉的传输。
   - 为什么返回假的 400 而不是抛异常：pinned adapter 对非 2xx 的 body 走 `providerError` → `INVALID_REQUEST`，消息原样进日志，且该 code 不在重试码表里（`llm-retry` 默认重试 `RATE_LIMIT/SERVER/TIMEOUT/TRANSPORT`），所以只拒绝一次、不进网络。
3. **App 的失败行带上事实**（`ProbeEngineViewModel.kt:742`）：`no model route (pdsh.deepseek.baseUrl was not supplied); the Worker refused the model request locally, so no request was sent`。这是**关于这次 launch 的事实**，不是对失败原因的断言；它不说 key 错。

**为什么两侧都做**：Worker 是唯一能拦住回落的一层（DSH 的回落发生在它内部），App 那层只是让用户看见同一句话——不是重复防护，而是同一个事实的两个呈现。**没有**在 App 里提前拒发：回合照常跑，才可能在设备上证明「请求在离开设备之前就被拒」。

**没做的（方向 a 的更强版本）**：不在 `:engine` 里拒绝 WebView 的一切非 loopback 子资源。那会顺手覆盖所有未来的第三方请求，但会改变整个引擎的网络策略，超出本车道；见 open questions。

### 零外网流量：设备证据（AVD 5604，android-35）

不传 `pdsh.deepseek.baseUrl`，`PDSH_MODEL_KEY_STATE=configured`（真 key 已按 §61 的办法导入设备），点「跑一轮」：

```
I PDSHHost: model route: none (Worker env PDSH_MODEL_ROUTE=none, PDSH_MODEL_ROUTE_MISSING=base-url);
            pdsh.deepseek.baseUrl was not supplied: the Worker refuses model requests locally instead of
            falling back to the public DeepSeek API
D PDSHEngine: console WARNING: pdsh: no model route for this launch: pdsh.deepseek.baseUrl was not supplied.
            The host mounted no model edge, so the Worker refuses this model request instead of letting
            llm-deepseek fall back to its public base with the non-secret placeholder credential.
            No request was sent and no credential left the device. PDSH_MODEL_KEY_STATE=configured:
            the missing fact is the endpoint, not the credential.
E PDSHAppTurn: APP_TURN_FAILED reason=incomplete: kinds=turn_started,user_message,…,turn_ended reason=error;
            no model route (pdsh.deepseek.baseUrl was not supplied); the Worker refused the model request
            locally, so no request was sent
```

```
grep -c 'api.deepseek.com' ./logcat.txt        → 0
grep -c 'subresource HTTP 401' ./logcat.txt    → 0
```

`dumpsys netstats detail` 前后（App uid 10207）：

```
before  mAppUidStatsMap: 10207  25354  71  25354  71
        mStatsMapB:      1 lo 0x0 10207 0   208  4   208  4
        mIfaceStatsMap:  2 dummy0 10907 47 22398 103 | 16 wlan0 1500 15 3160 34 | 1 lo 33804 122 33804 122
after   mAppUidStatsMap: 10207 183546 317 183546 317
        mStatsMapB:      1 lo 0x0 10207 1 158192 246 158192 246
        mIfaceStatsMap:  2 dummy0 10907 47 22398 103 | 16 wlan0 1500 15 3160 34 | 1 lo 191996 368 191996 368
```

**uid 10207 的增长全在 `lo` 上；唯一的外网接口 wlan0 的字节/包计数前后一字未变。**

### 反向验证：把 Worker 半边退回旧 bundle → 请求回来了

同一台设备、同一个不传 baseUrl 的 launch，只把 `worker-entry.js` 换回 APK 里那份（无 guard）：

```
W PDSHEngine: subresource error -2 (net::ERR_INTERNET_DISCONNECTED) for https://api.deepseek.com/anthropic/v1/messages
D PDSHEngine: console WARNING: session-title-service: … automatic title generation failed:
              Error: DeepSeek Messages transport failed
E PDSHAppTurn: APP_TURN_FAILED reason=api_aborted
```

`api.deepseek.com` 出现 **5 次**（title + turn + 重试），全部是 WebView 层真实发起的子资源请求。

**如实说明**：这台 AVD 没有可用外网（wifi 连上却拿不到租约，`ping` 报 `Network is unreachable`），所以旧 bundle 的尝试停在 `net::ERR_INTERNET_DISCONNECTED`，没有走到 §61 的 401。同一 URL 从宿主访问返回 401（`curl -o /dev/null -w '%{http_code}'` → `401`），所以「有网设备上这一行就是那条 401」。**判据不是状态码，是「有没有向第三方发包」**：旧 bundle 有请求、新 bundle 零请求，同一台机器、同一套测量。

### 回归：有 baseUrl 时行为不变

`bash android/tools/run-app-turn.sh --no-build`（scripted upstream + `adb reverse` + `pdsh.model.proxy=false`）：

```
I PDSHHost: model route: direct (Worker env PDSH_MODEL_ROUTE=direct); the Worker talks to the launch's base URL directly
I PDSHAppTurn: APP_TURN_OK session=session-d29af2ab-… kinds=…,tool_call,tool_result,…,turn_ended reason=completed tool_edges=true
upstream: MODEL_REQ path=/v1/messages title=true / title=false / tool_result=true
```

**这一轮跑的是装了 guard 的新 bundle**（materialized `worker-entry.js` 里 `grep -c "no model route for this launch"` = 1），guard 一次都没触发（日志里 0 行），因为 `direct` 不解锁拒绝。旧 bundle 的同一脚本同样全绿（12/12 assertions）。

### 数字

```
plugins npm run typecheck                      通过
worker-entry 单测（PDSH_DSH_CHECKOUT 已设）     190 tests / 188 pass / 1 fail / 1 skipped
  └ 唯一 fail：abort-journal（agent-preset/invalid: workflow-ptc waiting for ptcRuntime），
    harness 不 import entry.ts、失败在 session/create，与本节无关（既有问题）
新增 model-route.test.ts                       9/9
:dsh:testDebugUnitTest（含新增 ModelRouteTest） 197 tests / 0 failures（ModelRouteTest 7/7）
structure_check                                11/11
```

### Open questions

1. **App 不提前拒发**：这是选择，不是遗漏。代价是「没配好」的一次点击仍要走完 channel/session 三个调用才失败。若要更快的 UX，加一个 `runTurn` 前置判断即可，但设备上就看不到 Worker 的拒绝了。
2. **`:engine` 的统一出口**：现在只管模型协议路径。若要把「Worker 不得把占位符发给任何非 loopback 端点」变成全局不变量，应该在 `WebViewClient.shouldInterceptRequest`/`onReceivedHttpError` 那一层（或 `:net`）做，而不是继续在 fetch 上加路径判断。
3. **`PDSH_MODEL_ROUTE` 的版本偏斜**：未知值只警告、不拒绝（不猜第四种路由）。APK 与 Worker 镜像同包发布，所以偏斜只可能来自热推或测试。
4. **`pdsh.model.proxy=false` + 真端点**仍是「占位符发到真 API」的路径（诊断用、显式 opt-in）。本车道没动它；它是否也该拒绝是产品决定。
5. **同一占位符的其它出口没覆盖**：`web-search-deepseek` 的 `apiKeyEnv` 也是 `DEEPSEEK_API_KEY`，走 `/v1/search`；手机 profile 里它默认 disabled、宿主也不设 `PDSH_WEB_SEARCH_PROVIDER`，所以当前没有流量。guard 只认模型协议路径（`/v1/messages`、`/v1/files`）；若将来打开搜索，应当把 `/v1/search`、`/v1/tools` 一并纳入，或改用第 2 条的全局不变量。

## 63. P27 的方法论价值：**不要从「缺失」推断「事实」**

P27 在修复里做了一个判断，比修复本身更值得记。它写道：

> **「env 里没有 `DEEPSEEK_BASE_URL`」是二义的**（挂 edge 时 engine 也先省掉再注入），所以 Worker 不能自己推断，**必须宿主显式说**。

### 为什么这条重要

今晚有 **5 个**缺陷的根因都是「从缺失推断事实」：

| 从什么推断 | 推成了什么 | 后果 |
|---|---|---|
| `EACCES` 换成 `ENOENT` | 「不存在」 | 模型以为设备上没有会话 |
| torn tail 超预算 | 「损坏」 | 工作区报废 |
| 未列出的 epoch | 「损坏」 | 工作区报废 |
| 快照省略被拒子树 | 「不存在」 | `os error 44` |
| **env 里没有 base URL** | **「没有模型路由」→ 回落官方 base** | **误配置发外网流量** |

**每一次都是「我没看到 X，所以 X 不存在」。**

P27 没有继续这个模式，而是**新增了一个显式事实**：

```
PDSH_MODEL_ROUTE=none
PDSH_MODEL_ROUTE_MISSING=base-url
```

**「不知道」变成了一种可以表达的状态，而不是被折叠成某个已知值。**

### 零外网流量的证据（三重）

| 证据 | 结果 |
|---|---|
| `grep -c 'api.deepseek.com'` | **0** |
| `grep -c 'subresource HTTP 401'` | **0** |
| netstats `wlan0` 前后 | **一字未变**（`1500 15 3160 34`）；流量全在 `lo` |

**第三条最硬**：它不是「日志里没看到」，是**网卡计数器没动**。

### 它诚实标注了反向验证的一个局限

> 该 AVD 无可用外网（wifi 无租约），所以旧 bundle 停在 `ERR_INTERNET_DISCONNECTED` 而非 401。**判据是「有没有向第三方发包」，不是状态码。**

**这句话很重要**：它没有因为「没看到 401」就说反向验证成功，而是**把判据换成了正确的那一个**（有没有发包），并说明为什么证据形状与预期不同。

### 错误信息现在同时说清三件事

```
no model route (pdsh.deepseek.baseUrl was not supplied);
the Worker refused the model request locally, so no request was sent.
PDSH_MODEL_KEY_STATE=configured: the missing fact is the endpoint, not the credential.
```

| 事实 | 说了什么 |
|---|---|
| 缺什么 | `baseUrl was not supplied` |
| 发生了什么 | `refused locally, no request was sent` |
| **不是什么** | **`the missing fact is the endpoint, not the credential`** |

**第三行是新的**：以前的错误只说「缺什么」，现在还会**排除一个错误猜测**。因为旧 bug 就是把模型引到「查 key」上去。

### 一条测试手法：tripwire

`model-route.test.ts` 里有一条「**tripwire fetch 从未被调用**」——放一个会在被调用时爆炸的 fetch 替身，断言它没被碰到。

这比「断言没有发出请求」更硬：**它证明的是「代码路径根本没走到那里」**。

### 剩下的（P27 报的，都不是阻塞）

| # | 项 |
|---|---|
| 1 | App 不提前拒发（一次误配置点击仍要走完 channel/session 三个调用才失败） |
| 2 | 只拦模型协议路径；「占位符不得发往任何非 loopback 端点」的全局不变量该在 `:net` 层做 |
| 3 | 未知 `PDSH_MODEL_ROUTE` 值只警告不拒绝（**不猜第四种路由**——这个判断对） |
| 4 | `pdsh.model.proxy=false` + 真端点仍是占位符发真 API 的显式 opt-in 路径 |
| 5 | `web-search-deepseek` 的 `/v1/search` 也带同一占位符（当前 disabled），未纳入 guard |

**第 3 条的判断值得记**：遇到不认识的枚举值，**警告而不是猜**。今晚有几处正好相反（把 UNKNOWN 折成 NO）。

## 64. 我自己的数字是假的：`test-count.sh` 会把「跑了一半」报成「0 failing」

### 发现过程

我例行复核测试数，得到 **1284 / 0 failing**。而半小时前是 **1453**。

**少了 169 条却显示「0 failing」**——这正是我今晚一直在抓的假绿形状，只不过这次在**我自己的测量工具**里。

### 根因

`:net` 只跑了 **3** 条（应 180）。原因链：

1. 另一条车道为验证「凭据不得进日志」跑了 `:net:test --tests '*KeyMaterialLoggingTest'`（3 条）
2. 这一次**过滤运行**只留下 1 个结果 XML
3. 之后的**全量运行**被 Gradle 判为 **UP-TO-DATE** → 不重新生成结果
4. `test-count.sh` 老实读 XML → 读到 3 条

**19 个测试源文件，1 个结果 XML，报告「0 failing」。**

### 修法：把「结果文件数 < 测试源文件数」变成警告

```bash
srcs=$(find "$src_dir" \( -name '*Test.kt' -o -name '*Tests.kt' -o -name '*Test.java' \) | wc -l)
xmls=$(find "$name/build/test-results" -name '*.xml' | wc -l)
if [ "$srcs" -gt 0 ] && [ "$xmls" -lt "$srcs" ]; then
  partial="  [PARTIAL? ${xmls} result files for ${srcs} test sources]"
fi
```

并在末尾 `WARN` 一句，点名是哪些模块、并给出修法（`--rerun-tasks`）。

**模式名用的是 `*Test.kt` 结尾**，不是 `*Test*`：`HostWalTestSupport.kt` 是 helper，不该计入——第一版用宽匹配，`:core`/`:net` 在**健康状态下也报警**，是假阳性。

### 双向验证

| 状态 | 结果 |
|---|---|
| 全量 | **1461 tests, 0 failing**，**无警告** |
| 造一次过滤运行 | **1284 tests**，`WARN: … :net`，`[PARTIAL? 1 result files for 17 test sources]` |

**两个方向都验了**：健康时不吵，异常时点名。

### 真实数字

```
1461 tests, 0 failing      ← 不是 1284，也不是我先前报的 1453
```

`:net` 180、`:core` 174、`:dsh` 197、`:engine` 92、`:lib` 473。

### 这条的教训

**我今晚说过「1402 个 JVM 测试一条都没抓到那些缺陷」——那个数字本身也是不可靠的**，因为它来自同一个工具。

**测量工具的错误比被测代码的错误更危险**，因为它会让你以为一切都对。

今晚这一类已经是**第三次**：

| 次 | 测量工具 | 错在哪 |
|---|---|---|
| 1 | `WebViewKernelProbe` | 问**原生**，而 worker 跑**垫片** → 能跑的内核被判不能跑 |
| 2 | 同一个 probe | 装 **1 个**属性，worker 装 **14 个** → 测的是空 surface |
| 3 | **`test-count.sh`** | **读部分结果，报「0 failing」** |

**三次都是「工具的观测范围小于它声称的范围」。**

### 新增的一条验收标准

以后报测试数，必须同时满足：

1. `test-count.sh` **无 `WARN`**
2. 报出的数字与「各模块源文件数 × 大致比例」不冲突
3. **过滤运行之后必须 `--rerun-tasks` 再报数**

**「0 failing」不是结论，「1461 条全跑了且 0 failing」才是。**

## 65. 「admission 关闭烧 mseq」是**宿主用法错**（P26）——并纠正了 P22 的两处读码错误

### 契约原文（P26 纠正了条款位置：是 `channel.md` §3.4，不是 `wal.md`）

`channel.md:87`（§3.4）：

> … It is not a protocol error and **neither reuses nor skips an mseq**: the worker answers with a complete `op = 1` write at the **next mseq** …

`wal.md:113-119`（§5.1）：

> **keep the mismatching record and every later append of the path in the WAL. An accepted record is never discarded and never rewritten.**

`channel.md:290-291`（§7 第 6 条）：

> While admission is closed the worker starts no new tool work … **flushing and in-flight work continue.**

`budgets.md:16`（Draining）：**wait for in-flight work**。

### 判定：**宿主错，worker 对**。两条独立缺陷

| # | 缺陷 |
|---|---|
| **c1** | 用 D14 admission 去闸 VFS 写路径，违反 §7 第 6 条与 Draining 语义——**Draining 明确要等 in-flight work，结果把它的写全拒了** |
| **c2** | 对一条**没被 append 的** mutation 回 `VFS_RESYNC`，不是 §3.4 的用途；worker 的应答是下一个 mseq 的新写，宿主 `expected_mseq` 不动 → **必然 `BAD_MSEQ`** |

### 它纠正了 P22 的两处说法（这是本次最有价值的动作）

**1.「不消费 mseq」不准确**：§3.4 是「neither reuses nor skips」——修复写**占下一个 mseq**，只是不复用、不跳过。

**2.「bundled worker 对 VFS_RESYNC 只 decode 后 return」是错的**：

> `acceptNonHello`（`ws-client.ts:805`）只是校验后 return，紧接着 `acceptFrame` 调 `this.notify(frame)`（`:735`），`installResyncHandler`（`entry.ts:2147`，挂载点 `:695`）就挂在这个 listener 上，**会整文件重发**。

**P22 读代码时漏了 `notify(frame)`。**

**设备证据**：修前那轮 10 秒里 **21,574 条 defer**、mseq 冲到 **22,552** ——正是「宿主 RESYNC → worker 重发 → 又 defer → 又 RESYNC」的**放大环路**。

### 参照实现（iOS）

`ChannelServer.swift:820` 的 `.vfsMutation` 分支**没有任何 admission 检查**（admission 只查 `.execRequest`）。`PhoneDSHHost.swift:608-612` 原文：

> **VFS_MUT frames are not admission-gated on an already-connected channel**

**iOS 早就做对了，Android 抄错了一个闸。**

### 设备前后对比（同设备、同 prompt、同场景）

| | 修前 | 修后 |
|---|---|---|
| `defer` | **21,574** | **0** |
| 最终 mseq | 冲到 22,552 | `last_mseq=977, materialized_upto_mseq=977` 严格连续 |
| 错误 | `BAD_MSEQ: expected 978, got 22552` | **0 次** |
| 通道 | 自杀 | 未断 |
| 回合 | `APP_TURN_FAILED reason=channel_lost` | **`APP_TURN_OK … reason=completed`** |
| 文件 | 停在 3 个 | **120 个全部物化** |

**UI 实帧计数**（dump 取在窗口内，证明 ACK 照发）：

```
t0（closed）:  收帧=84   发帧=51
t1（14s 后仍 closed）: 收帧=206  发帧=173   ← 窗内 122 收 / 122 发
after（open）: 收帧=354  发帧=304  回合=完成  最近错误=—
```

### 反向验证红出了**完全一样的错误**

```
VfsSinkTest > admissionClosedAndReopenedKeepsTheWorkersMseqContiguous FAILED
  AssertionError: no BAD_MSEQ after admission reopened;
  errors=[{"code":"BAD_MSEQ","ref_seq":586,"message":"expected mseq 105, got 585"}]
```

**单测的错误文本与设备日志同形**——这是今晚反复验证过的高质量信号。

### 修法

删掉 `VfsSink` 的 `admission` 构造参数与 `emit(Resync)` 分支，`Parsed -> append(...)` 无条件走写路径；`PhoneDshHost` 不再给 sink 传 `AdmissionGate`，**`HostExec` 的闸保留**（那才是「新工作」）。

现在 `VFS_RESYNC` 只剩**真实物化失配**一个来源。**worker 一行未改**——它本来就对。

### ⚠️ 它挖出**数据丢失级**问题（已派 P28）

不是「内容一致性没有对账证据」，是 **`wal.md` §8 的 boot overlay 在 Android 上根本没实现**：

> The host packs the materialized tree as an **uncompressed ustar archive** (the boot overlay) … **rebuilt for each boot** and is an input, not an authority.

Android 只下发 `?image=`（静态 APK 镜像），**没有任何 `?overlay[]=`**。

设备实测（冷启动 = 完整 recovery + 回放 1272 条）：

```
建了 600 个文件（全在 WAL 与宿主 materialized）
→ 冷启动 → `ls /dsh/workspace > listing.txt`
→ 宿主读 listing.txt：里面只有 listing.txt
```

**600 个文件，worker 一个都看不到**；而 worker 还在这个「空工作区」上继续写并进入 WAL——**覆盖 WAL 里更新的内容**。

**而且 P22 的自愈正是靠重载页面**，所以**每一次通道恢复都会放大这个 bug**。

已派 P28，核心验收：**冷启动后 `ls /dsh/workspace` 能看到之前建的文件**。

### 它留的三条待办

| # | 项 |
|---|---|
| 1 | 「worker 活着但 WAL 不得前进」的状态（HandingOff/Remote/Reclaiming/Failed）契约**没有拒收帧**；正确解是**停 mutation 源**（Swift 有 `suspendRuntimeForRemote`），**不要在 sink 重新加闸** |
| 2 | RESYNC 放大：`emit(Resync)` 对每条 append 都调，靠 `AppendAck.resync` 仅在新请求时非空来满足「one outstanding per path」——这条不变式**没有专门测试钉住**，建议补 |
| 3 | worker mseq **永不向下重锚**（`max(local, hello.next_mseq)`）→「宿主任何非契约拒收都不可恢复」 |

## 66. boot overlay：**数据丢失级** bug 已闭（P28）

### 问题的形状

**worker 侧早就实现了 overlay 消费，宿主从来没下发过。**

`web-boot.ts:221` → `entry.ts:504` → `runtime-binding.ts:168` → runtime `worker-host.ts:190` 一路都在——**只是没人送**。

**这是「已实现、待接线」的第七个实例，也是唯一一个默默丢数据的。**

### 核心验收（emulator-5606，API 35）

```
冷启动:
I PDSHEngine: boot overlay: serving /image/overlay/ce1497…tar
  (212 entries, 0.5 MiB tree, 0.7 MiB ustar, 0.1 MiB gzip, 26 ms, materialized_upto_mseq=628)
I PDSHEngine: handshake: proto=1, … next_mseq=629, acked_mseq=628

冷启动后一轮 bash: `ls -1 /dsh/workspace > listing.txt; wc -l < listing.txt`
worker tool/result 原文 = 156
宿主 files/xl/materialized/workspace/listing.txt = 156 行，其中 r1/r2/r3 共 150 个
```

另一次冷启动：`(228 entries … materialized_upto_mseq=725)` / `next_mseq=726, acked_mseq=725`。

### 反向验证（同设备、同数据、只关开关）

```
--ez pdsh.boot.overlay false
→ 日志里零 boot overlay 行
→ 同一条 ls 后，宿主 listing.txt 只剩 1 行
→ 而 materialized/workspace 磁盘上仍是 156 个文件
```

**worker 用空视图覆盖了宿主上真实存在的 156 行。** 再切回 overlay-on 跑同一轮，恢复 156 行。

**这直接证明了「数据丢失」这个定性，也证明了修复是因果。**

### 三个设计判断

**1. 「水位括号」而不是事后对账**

> 整文件写没有 base 证明（`channel.md §3.1` 没有内容 hash），所以「worker 视图过期」不可能靠事后对账修好，**只能靠每次 boot 都是新快照**。

实现：pack 前后读 `materializedUptoMseq`，跨了就丢弃重打（3 次仍跨 → fail loud），日志把 `materialized_upto_mseq=` 打在 entries/size 同一行，可与 HELLO 对照。

**没有**加 wire 字段（HELLO 的 `acked_mseq` 是 WAL tail / D17，不是 materialized 水位；resync 挂起时两者不同）——加字段属 `channel.md` 变更。

**2. 超限 = 拒绝，不是截断**

```kotlin
BootOverlayException(Refusal.TOO_LARGE, bytes, limit, entry)
```

上限取 tier 的 `vfsLogicalBytes`（overlay 会成为 worker `MemoryVfs` 的字节，超过它这台设备本来也 boot 不了）。测试钉住两件事：**目标文件不存在**、**源不返回更小的包**。

**3. 字节可复现**

`mtime=0`、名字排序、POSIX mode、ustar name/prefix 100/155 拆分——同样的树打出同样的字节。

### ⚠️ 一处与契约字面不同（已记入契约问题）

> **§8 写 "uncompressed ustar"，D21（gzip 包一层）只落在 iOS 代码与文档里，`spec/v1` 没有；runtime 强制 gzip。**

runtime 的 `storage/image-gzip.ts` 对非 `1f 8b` 开头的 body 直接报错，image 与 overlay 共用 `readImage`。iOS 的 `OverlayPacker.swift` 已如此（「D21 supersedes the earlier uncompressed tar overlay」）。

**我们实现的是 gzip 包 ustar，spec 缺 D21 的文字。**

### ⚠️ 它顺手发现另一个阻塞级 bug（已派 P30）

```
worker: API_ABORT reason=canonical JSON accepts integers only: 481.7056…
App:    APP_TURN_FAILED reason=api_aborted
```

**只要模型请求失败一次（429/5xx/网络抖动）→ 触发重试事件 → `delayMs` 是浮点 → canonical JSON 拒绝 → 整轮打死。**

**任何一次可恢复的重试都变成硬失败。**

而 `docs/receipts/phase0-a1-2026-10-29.json:88` 早就决定了「嵌套 `delayMs` 只在 phone mux projection 取整」——**决策写了，没实现**。

### 数字

```
JVM 测试  1475 / 0 failing，无 WARN（:engine 106，新增 BootOverlayTest 14 条）
structure 11/11
```

## 67. 进程替换回归（P29）——并纠正了**我给的验证方法**

### 先纠正一条上游结论

P13 曾报告「golden/contract 8 条**用修前引擎复跑仍是 509/512，已证明 pre-existing**」。

**P29 证明这个结论对这 3 条不成立**：

> 他们大概率只回退了 just-bash patch（引擎），而写根车道的**分类改动仍在树里**，所以这 3 条一直红。

### 判定是回归：三种方法互相印证

| 方法 | 结果 |
|---|---|
| (a) 代码考古 | `git diff` 显示写根车道把 `rethrowWrite` 的抛出从 plain Error 改成 `markWriteDenied(...)`；`shell.ts` 新增 `writeDenials.render(...)` 且在 `exitCode===0` 时**强制置 1**。HEAD 版两处都没有 |
| (b) 复刻修前分类 | 临时把 `markWriteDenied` 还原成 plain `Object.assign` → **三条全绿**（`same` / `b` / `a,1 b,2`）；恢复后红 |
| (c) **按我的建议关掉 `assertWritable`** | ❌ **假阴性**：三条**仍然红** |

### 我要认的一处：我给的验证方法是错的

我在任务里写「临时把写根守卫关掉（`assertWritable` 直接放行）跑这三条 → 若通过，就是回归」。

**P29 实测证明这不成立**：

> golden harness 用 **real-directory root**，`writePolicyEnabled=false`，**`assertWritable` 根本不在路径上**。

**真正的回归机制是「标记 + 记录 + 渲染」，不是 gate。**

如果它照我说的做，会得出「不是回归」的错误结论。

**这是今晚第 N 次「我的推理错了，被实测纠正」——而这次错在「我以为守卫只有一处」。**

### 真实机制

just-bash 的进程替换**依赖「基座写失败」这个信号**才会 mount 私有内存 FS：

```
先写基座 FS → 写失败 → mount 私有内存 FS → 进程替换可用
```

写根车道让这个「失败」带上了 **WRITE_DENIED marker** → `recordExecWriteDenial` 记录下来 → 渲染 roots 句 + **强制 exit 1** → 进程替换失败。

**「内部可恢复错误」被升级成了「用户可见的拒绝」。**

### 修法：`/dev/fd` 是**引擎保留命名空间**，基座回 plain ENOENT

```ts
ENGINE_RESERVED_ROOTS = ['/dev/fd']   // 严格在 /dev/fd/ 之下
```

基座 VFS 对它**一律回 plain `ENOENT`、不落 node:fs、不存任何字节**。因为**没有 marker**，`recordExecWriteDenial` 不记录 → 不渲染 roots 句 → 不强制 exit 1 → just-bash 正常 mount。

**根表 `WORKER_ROOTS`、`writeRoots()`、`writableRootsLine()` 一个字都没动。**

### 为什么**不能**把 `/dev/fd` 加进可写根（这个判断很关键）

P29 自己论证了：

| 方案 | 后果 |
|---|---|
| 加进根表当 device 类根 | (i) 父目录若存在，写入会**成功**，mount 永不安装，**fd 内容落进用户 VFS**；(ii) `mkdir /dev/fd` 被放行，**产生无预算记账的真实字节**——**直接放宽可写面**，且结果依赖父目录是否恰好不存在 |
| 对 `/dev/**` 开例外 | `/dev/null` 已是 device 根；`/dev/zero`、`/dev/std*` 不属于引擎 mount 点。**只有严格在 `/dev/fd/` 之下才是** |
| **选定：保留命名空间 + ENOENT** | **不是「允许写」，而是「按不存在拒绝」**——所以不存在绕过 |

### 结果

```
golden   512/512（修前 509/512）
phone-plugins  fail 18 → 10
消失的 8 条正好是 golden/contract 组
```

| 检查 | 结果 |
|---|---|
| 三条 vector | `same` / `b` / `a,1 b,2`，exit 0，stderr 空 |
| `>(...)` 、嵌套 `<(<(...))` | 也 exit 0，`/dev` 不被创建 |
| `writableRootsLine()` | **文案未变**（仍 5 个根） |
| 四个非法路径 | 仍 exit 1 + `EACCES + roots 句` |
| `/dev/fd/63` 直写 | exit 1 + ENOENT，不建文件 |

### 反向验证

```ts
ENGINE_RESERVED_ROOTS = Object.freeze([])
```

→ 三条立即重新红，**stderr 与原始症状逐字一致**（stdout 仍是正确内容）。恢复后 golden 回到 512/512。

### 剩余 10 条失败（与本车道无关、修前就在）

`phone-feature-admin` 文件级失败 1、python artifact/compression 6、python cleanup 2、Node Timeout 1。

### 它留的一条未统一

> `/dev/fd` 现在是「引擎保留、基座 ENOENT」，其他执行面（`python`/`git`/`write` 工具）写 `/dev/fd/x` 仍走 write policy 得 **EACCES + roots 句**（合理：它们没有 just-bash 的 mount）；若希望所有面统一成 ENOENT 可再议。

**保持现状是对的**：just-bash 需要 ENOENT 作为 mount 信号，其他面没有这个需求，给它们 EACCES 是更诚实的答案。

## 68. 最终原子构建与设备验证（收尾）

### 构建（一次做完，四产物 + APK）

```
worker-entry.js  3,818,971 B  md5 2cdf9b3b49144f6e84876bf9985a405b
image.tar.gz    25,245,959 B  md5 a64ebda306f8b313bcdb201d9efa953d
app-debug.apk  125,531,183 B  md5 7f88c3b0e21911c680bc64c337e3ae4a
bundle-freshness: 6 fresh, 0 stale, 0 absent   → PASS
```

设备侧 md5 与本地**逐字节一致**（`install -r` + 删 `files/worker` + 删 `worker.version` 强制重解包，key 存活）。

### 修复在产物里的证据（不是「我改了源码」）

| 位置 | 标记 | 计数 |
|---|---|---|
| `worker-entry.js` | P16 snapshot denial | 50 |
| | P17 `values()` | 6 |
| | P28 boot overlay consumer | 66 |
| | **P30 mux projection** | **1** |
| `image` 内 `shell-ext/lib/chunks/*.js` | P8 denial renderer | 3 |
| | P20 listing invisibility | 2 |
| | **P29 `/dev/fd` reserved** | **2** |

### 设备验证 11 项（最终 APK，真模型回合 `APP_TURN_OK reason=completed tool_edges=true`）

| # | 命令 | 结果 |
|---|---|---|
| 1 | `diff <(echo a) <(echo a) && echo same` | **`same`** exit 0 ← P29 |
| 2 | `ls /dsh/home` | 4 项，**无内部根** ← P20 |
| 3 | `echo /dsh/home/*` | 4 项，**glob 不泄漏** ← P20 |
| 4 | `ls /dsh/home/sessions` | **EACCES** exit 2 |
| 5 | `rg -n session_ /dsh/home/sessions` | **EACCES** exit 2 ← P12 |
| 6 | `jq . /dsh/home/storages` | **EACCES + remediation** exit 2 ← P16 |
| 7 | `python3 -c 'print(6*7)'` | `42` |
| 8 | `jq -n 1` | `1` |
| 9 | `phone info` | 真机 JSON |
| 10 | `printf x > /dsh/config/y` | **EACCES + writable roots** ← P13 |
| 11 | `stat /dsh/home/tool-journal` | **EACCES** exit 1 |

### 收尾时发现并修掉的**跨车道集成缺口**

第一次跑这 11 项时，**第 6 项失败**：`jq . /dsh/home/sessions` 给 `No such file or directory (os error 44)`。

**根因是两个车道的修复在同一个路径上打架**：

| 车道 | 做了什么 |
|---|---|
| **P16** | 快照捕获时记录「被拒的根」，让 guest 显式访问得到 EACCES |
| **P20** | `readdir` 过滤掉内部根的名字（隐藏名字） |

**P20 的过滤删掉了 P16 记录拒绝所依赖的输入**——`walk` 通过 `readdir` 发现子项，名字被隐藏后**永远看不到** `/dsh/home/sessions`，于是既不 stat、也不记录拒绝，guest 拿到 ENOENT。

**「不可见」和「被拒绝」是两个性质，但实现上是同一条数据流。**

修法：快照捕获在遍历之后**显式 stat 每个 `EXEC_INTERNAL_ROOTS`**，命中 EACCES 就记录拒绝。

```ts
for (const internal of EXEC_INTERNAL_ROOTS) {
  const owner = roots.find(root => isWithinRoot(normalizeAbsolutePath(root), internal))
  if (owner === undefined) continue
  try { await backend.stat(internal) }
  catch (error) { if (omissionOf(error) === 'denied') recordDenial(internal, error) }
}
```

并更新了一条过时的测试期望（原来只期望 `sessions` 被记录，实际三个内部根都该被记录）。

**修后设备原文**：

```
jq . /dsh/home/storages
EACCES: session-internal state under /dsh/home/storages is not readable …
jq: error: Could not open file /dsh/home/storages: Permission denied (os error 2)
```

**这条值得记**：它不在任何一路的验收里——**每一路的单测都对，合起来却有一个假陈述**。只有当所有车道停手、在最终产物上跑一次全量验收时才暴露。

