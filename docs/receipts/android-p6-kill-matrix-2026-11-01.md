<!-- SPDX-License-Identifier: MIT -->
# P6 证据：进程被杀矩阵 + reclaim token 可用性矩阵（2026-11-01）

配套决策记录：[android-durability-decision-2026-11-01.md](../design/android-durability-decision-2026-11-01.md)

本文件是本轮 **A（kill 矩阵）** 与 **C（reclaim token 矩阵）** 的原始证据摘要。每条结论都带「测到的」与「没测到的」，
不留「应该能行」。复跑方式、脚本、设备与命令都在下面。

## 0. 环境与设备

| 项 | 值 |
| --- | --- |
| AVD | 自建 `pdsh-p6-5566`（`system-images;android-35;google_apis;arm64-v8a`，pixel_6，4 核 / 2 GB） |
| 端口 | **5566**（未使用 5556/5558/5560/5562/5564） |
| 启动参数 | `-port 5566 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect`（`-no-window` 必须） |
| API | 35（Android 15），`ro.product.cpu.abi=arm64-v8a` |
| APK | `android/app/build/outputs/apk/debug/app-debug.apk`（本轮改动后重编，`:app:assembleDebug`） |
| key | `sk-…` 经 `run-as com.phonedsh.probe tee files/import-key.txt` 落盘，重启由 `ApiKeyStore.importDevelopmentKey` 导入后删除明文 |
| 模型 | 真实 `https://api.deepseek.com/anthropic`（非脚本上游）；回合内出现真实 `tool_call`/`tool_result` |
| 存储 | 宿主 QCOW2（`userdata-qemu.img: QEMU QCOW2 Image (v3)`），**无** eMMC/UFS write cache |
| 清理 | 结束后 `emulator -avd pdsh-p6-5566` 进程 kill + `avdmanager delete avd -n pdsh-p6-5566` |

判读方式：每次快照都是 `run-as tar -cf - files/xl` 拉回宿主后离线解析——WAL 按 `wal.md` §2/§3 帧
（`len|crcc32c|mseq|body`，大端）逐条校验 CRC32C；journal 按 `JournalStore` 自有帧（`len|crc|jseq|record`）校验；
session JSONL 逐行 `json.loads`。**「torn=[]」= 文件里没有半截帧且 CRC 全过**；不是「没看」。

> 测量纪律（一条教训）：**不要在恢复窗口里做活体 tar**。本轮第一次 `recovered` 快照在
> `wal/1: on` 之后 10 s 拍，抓到 66 个条目中的 32 个且 `journal/` 整目录缺失 —— 那是恢复期
> `materialized/` 暂存交换 + journal 重开造成的活体读伪影，不是丢数据（同一时刻 `run-as ls` 五件都在）。
> 最终快照统一为「先 force-stop，再 tar」。

## 1. A — kill 矩阵（每格：杀前 / 杀后 / 恢复后）

统一回合输入（真实模型）：`用 shell 工具执行这一条命令：sleep 20; echo slept。只做这一件事，然后把输出贴出来。`
「回合中」的判定不是猜时间，而是**轮询 materialized session 里出现 `tool/call` 且还没有 `turn/end`**。

「杀前」用一次**廉价 probe**（文件大小 + 每 session 行数）记录；「杀后」是进程已死后的完整 tar，其记录数是**杀前状态本身**
（进程级杀法不改文件；A1 实测杀前/杀后每个 WAL 与 journal 文件字节数逐一相等），所以记录数一列同时就是杀前值。

| # | 杀法 | 时机 | 杀前（WAL 记录 / journal 记录 / 目标 session） | 杀后 | 恢复后 | 半截记录 | 会话完整 | fail-loud | 数据丢失 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | `am force-stop` | 前景回合中（tool/call 在执行） | 13 段 / 265 条 / journal 24 条 / session 21 行（`turn/start`、`tool/call`、`job/registered`，无 `turn/end`） | 同左，`pidof` 空 | 14 段 / 267 条 / journal 24 条 / session 21 行，**逐项相同**，`wal/1: on` | 无（`torn=[]`） | 回合被中断，已写的 21 行一条不少；无 `turn/end` 是事实 | 是：`TURN_INTERRUPTED_PREVIOUS … reason=NO_CALLBACK` + 横幅「上次回合被中断」 | 无 |
| A2 | `am force-stop` | 空闲（回合已 `completed`） | 17 段 / 334 条 / journal 28 条 / session 28 行含 `turn/end` | 同左 | 18 段 / 336 条 / journal 28 条 / session 28 行含 `turn/end` | 无 | 完整 | 无需要（无中断）；无横幅 | 无 |
| A3 | `kill -9 <pid>`（`run-as kill -9`，同 uid） | 前景回合中 | 15 段 / 292 条 / journal 25 条 / session 21 行无 `turn/end` | 同左 | 16 段 / 294 条 / journal 25 条 / session 21 行 | 无 | 中断但已写记录全在 | 是：同上横幅 | 无 |
| A4 | `kill -9 <pid>` | 空闲 | 19 段 / 377 条 / journal 31 条 / session 28 行含 `turn/end` | 同左 | 20 段 / 379 条 / journal 31 条 / session 28 行 | 无 | 完整 | 无 | 无 |
| A5 | `am kill` | 后台（回合中先 HOME） | 21 段 / 404 条 / journal 32 条 / session 21 行无 `turn/end` | 同左，pid 空（确认被杀） | 22 段 / 406 条 / journal 32 条 / session 21 行 | 无 | 中断但记录全在 | 是：横幅 | 无 |
| A6 | `am send-trim-memory com.phonedsh.probe COMPLETE` | 前景回合中 | `pid=11189` | **`pid=11189`（没被杀）** | 后续 HOME+`am kill` 才被杀：23 段 / 435 条 / journal 33 条 / session 21 行 | 无 | 中断但记录全在 | 是（由后续 kill 触发） | 无 |
| A7 | `adb emu kill` → 冷启动 | 前景回合中（tool/call 在执行） | 23 段 / 435 条 / journal 12 文件 / session 第 5 行数据中 | VM 直接消失 | **23 个有效段（435 条）+ 2 个 0 字节段（00000024/25）→ `WAL_CORRUPT` → `wal/1: off` → Worker `PROTO_MISMATCH` 拒绝启动 → 工作区不可用** | **有**：被杀 session 的 `session.v4.jsonl` 第 5 行是 NUL 填充的半截行，tool-journal 同样以 NUL 结尾（可检出） | 否：被杀回合只有 5 行，`turn/end` 缺失；且整个工作区打不开 | 是（日志 + 横幅「工作区不可用（wal/1 off）」），但**没有产品内修复路径** | **有**：队列尾（`last_mseq` 已到 437，WAL 只到 435）+ 工作区可用性 |
| A8 | 注入：向最后一个段追加 16 字节伪记录 | 应用已停 | 段 25 = 14266 B | 14282 B | `WAL_TORN_TAIL_TRUNCATED boot=8a3f… segment=00000025.000000.xlwal keep_len=14266 dropped_bytes=16 previous_len=14282`，截断后 `wal/1: on`，`next_mseq=440` | 有（正是注入的半截帧） | 前缀完整，服务恢复 | 是：横幅「WAL 尾部被截断」 | 仅注入的 16 字节 |

### 1.1 逐格结论

- **A1–A5：进程被杀零丢失、零半截。** 五种进程级杀法（两种前景 × 两种时机 + 后台）杀前/杀后/恢复后的
  WAL 记录数、journal 记录数、目标 session 行数**完全一致**；恢复只增加恢复自身写的段（434→436 之类）。
  `journal` 侧每格都是 `journal: open (N session(s), X bytes, 0 torn tail(s) removed)` —— 一条都没截。
- **A6：`send-trim-memory` 不是杀。** `COMPLETE` 只投递 `onTrimMemory`，pid 前后都是 11189。
  **模拟器上无法用这条命令触发 LMK**（本轮没有伪造这一点）；「低内存类」的杀证据由 A5 的后台 `am kill` 承担，
  两者在进程终态上是同一类（无回调、页缓存保留）。
- **A7：`adb emu kill` 不是掉电，且结果比「丢最后一个纪元」严重。** 详见 §3 与决策记录 §4.3/§6。
- **A8：尾部可检出已被两条独立路径证明**（注入 + 真实 NUL 半截行）。
- **「杀前 = 杀后」不是措辞**：A1 的杀前 probe 与杀后 tar 里，13 个 WAL 段与 6 个 journal 文件的字节数逐一相等
  （14266 / 14266 / 126040 / 108496 / 14266 / 102579 / 87426 / 14266 / 66825 / 14266 / 72757 / 14266 / 72751 与
  4443 / 467 / 467 / 477 / 2112 / 999）；A3/A5/A6 同样成立。这正是 level-1 的机制：进程死掉不丢页缓存里已写的字节。

### 1.2 「fail-loud」的定义与本轮实际

本轮的 fail-loud 判据是三条同时成立：(a) 日志里有一条可检索的记录；(b) 屏幕上有非易失横幅；(c) 不把
「不知道」写成「正常」。修复前后：

| 事件 | 修复前 | 修复后（本轮） |
| --- | --- | --- |
| torn tail 被截断 | **完全静默**：`:app` 构造 `WorkspaceLog` 没传 sink，默认 `WalLogSink.NONE`，而 `wal.md` §10 第 2 步要求记录 boot id/段/偏移/丢弃字节 | `PDSHWal: WAL_TORN_TAIL_TRUNCATED boot=… segment=… keep_len=… dropped_bytes=… previous_len=…` + 横幅 |
| 回合被进程杀死 | **完全静默**：`InterruptedTurnStore`（`commit()` 落盘、零回调语义都写好了）在 `:app` 里从未被调用 | `TURN_MARKER_WRITTEN` →（被杀）→ `TURN_INTERRUPTED_PREVIOUS … reason=NO_CALLBACK` + 横幅「上次回合被中断」，下次启动消费并清除 |
| WAL 恢复失败、`wal/1 off` | **屏幕仍显示「运行中」**，Worker 已在 `PROTO_MISMATCH` 拒绝启动（只有 logcat 的 console ERROR） | 横幅「工作区不可用（wal/1 off）」+ `PDSHWal: WAL_UNAVAILABLE host_caps=…` |
| reclaim token 读不出 | 只有 `SecureLookup.Unreadable` 返回值，无任何界面 | 横幅「回收凭据失效 … reason=key-invalidated」+ `PDSHSecure: RECLAIM_TOKEN_UNREADABLE`（error 级） |

## 2. C — reclaim token 可用性矩阵

被测对象：`AndroidSecureStore`（`com.phonedsh.platform.android`）—— whitelist 的
`platform.keychain-credential-store` 明确说 reclaim token 与模型凭据**共用同一封装**，而探针 app 没有
handoff 端点，所以这里测的是「回收 token 会用的那个保险库原语」，**不是**一次端到端的 token 交换。
设备侧探针：`--es pdsh.secure.op put|get|del`（debuggable 才生效），只打印查找状态与安全 `reason`，从不打印令牌字节。

| # | 场景 | 操作 | 结果 | 判定 |
| --- | --- | --- | --- | --- |
| C0 | 基线 | `put` 32 B token → 重启 → `get` | `RECLAIM_TOKEN_FOUND bytes=32 level=SOFTWARE` | 可用 |
| C1a | 锁屏**设**密码 | `locksettings set-pin 1234`（`verify --old 1234` 通过）→ `get` | found bytes=32 | 可用 |
| C1b | 锁屏**改**密码 | `locksettings set-pin --old 1234 5678`（`verify --old 5678` 通过）→ `get` | found bytes=32 | 可用（与 `AndroidSecureStore` KDoc 的「key 不绑用户认证，改密码不会失效」一致） |
| C1c | 锁屏**清除** | `locksettings clear --old 5678`（`get-disabled=true`）→ `get` | found bytes=32 | 可用 |
| C2a | **升级安装**（保留数据） | `adb install -r` → `get` | found bytes=32 | 可用（数据与 Keystore 条目都在） |
| C2b | **卸载重装** | `adb uninstall` + `install` → `get` | `result=absent`，`RECLAIM_TOKEN_ABSENT` | token 真没了；不伪造、不静默重建 |
| C3 | **设备迁移 / 恢复时没有 Keystore key** | 取走密文 → `pm clear` → 只回填 `no_backup/secure-store/*.bin` → 启动 | `result=unreadable reason=key-invalidated`（error 级）+ 横幅「回收凭据失效」 | **fail-closed 正确**：不是 `Absent`，不重建，界面告知需人工重新配对 |
| C4 | **Auto Backup** | `dumpsys package`（flags 无 `ALLOW_BACKUP`）+ `bmgr backupnow com.phonedsh.probe` | `Package com.phonedsh.probe with result: Backup is not allowed` | 云备份不会带走 token；`res/xml/backup_rules.xml` 与 `data_extraction_rules.xml` 另把 `no_backup/secure-store`、`files/xl` 明确排除（第二层） |

### 2.1 结论

- **可用**：锁屏设/改/清密码、升级安装。三者在模拟器上都不失效；原因是 AES key 生成时**没有** `setUserAuthenticationRequired`，
  `KeyPermanentlyInvalidatedException` 只会由 auth-bound key 或 Keystore 条目消失/标签校验失败触发。
- **不可用且必须 fail-loud**：迁移恢复（只有密文、没有 key）。实测走 `Unreadable("key-invalidated")`，
  日志 error + 横幅，且**没有**被当成 `Absent`（`SecureLookup` 三态在实现层就没有合并）。
- **不可用但不属 fail-loud**：卸载重装 → `Absent`。这是真的「没有 token」，不是「读不出」；探针没有配对流程，
  所以没有可回收的远端工作。产品面若存在待回收会话，应由配对/回收流程提示，而不是由保险库把 `Absent` 说成故障。
- **范围限制（诚实）**：模拟器 `AndroidKeyStore` 没有 TEE/StrongBox，`level=SOFTWARE`（`AndroidSecureStore` 自报，非猜）；
  真机上认证绑定策略、StrongBox 可用性、OEM Keystore 实现都可能改变 C1 的结论，需真机复跑。

## 3. 本轮找到的真问题

| # | 级别 | 位置 | 问题 | 状态 |
| --- | --- | --- | --- | --- |
| BUG-1 | **阻断** | `:core` 恢复 + `wal.md` §7.2/§10 | 未列入 manifest 且连 header 都没有的 **0 字节段**被判 `WAL_CORRUPT` → `wal/1 off` → Worker 拒启动 → 工作区永久不可用；没有产品内修复路径。实测 `adb emu kill` 后必现（两个空段）。删掉这两个空文件后同一工作区恢复成功（`next_mseq=438, acked_mseq=437`），证明保留前缀完好 | **未修**（写权限外：`android/core`、`spec/`）—— 报告给 spec/`:core` 车道，建议见决策记录 §6 |
| BUG-2 | 高 | `:app` 组合根 | `WAL_CORRUPT` 后屏幕仍显示「运行中」，Worker 已 `PROTO_MISMATCH` 拒绝启动；只有 logcat 知道 | **已修**：`ProbeRecovery.raiseWalUnavailable` + `RecoveryBanner`，注入 0 字节段复现验证 |
| BUG-3 | 中 | `:app` 组合根 | `WorkspaceLog` 未传 sink，`wal.md` §10 要求的 torn-tail 记录实际被丢弃（默认 `WalLogSink.NONE`） | **已修**：`ProbeRecovery.walSink` → logcat + 横幅，A8 验证 |
| BUG-4 | 中 | `:app` 组合根 | 回合被杀后无任何「上次中断」报告：`InterruptedTurnStore` 已实现但 `:app` 从未写入 tombstone | **已修**：`beginTurn`/`endTurn`（`commit()` 先写标记，只有显式结束才清），A1/A3/A5/A6 验证 |
| BUG-5 | 中 | `:app` 组合根 | reclaim token `Unreadable` 没有任何用户可见面 | **已修**：启动审计 + 横幅（C3 验证） |
| — | 观察 | 测量方法 | 恢复窗口内的活体 `tar` 会读到 32/66 条目的陈旧树（`journal/` 缺失） | 不是产品 bug；快照纪律已改为「先 force-stop 再 tar」 |

修复的测试面：本轮所有修复都在 `:app`（探针组合根 + 一屏 UI），没有改 `:core`/`:platform*`/`:lib`/`spec`。
`android/tools/structure_check.py` 11 项全过。

## 4. 复跑

```bash
# 1) 建 AVD（不要用别人的端口）
avdmanager create avd -n pdsh-p6-5566 -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_6 --force
emulator -avd pdsh-p6-5566 -port 5566 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect &
adb -s emulator-5566 wait-for-device

# 2) 装包 + 部署 key（先让 app 跑一次以创建 files/）
adb -s emulator-5566 install -r -t android/app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5566 shell am start -W -n com.phonedsh.probe/.MainActivity
printf '%s' 'sk-…' | adb -s emulator-5566 shell "run-as com.phonedsh.probe tee files/import-key.txt"

# 3) 一格一格的 kill 矩阵（每格产出 /tmp/p6-matrix/<cell>/{before,after,recovered}.{xl.tar,logcat,prefs.xml}）
SERIAL=emulator-5566 bash android/tools/kill-matrix.sh force-stop-foreground force-stop-foreground
SERIAL=emulator-5566 bash android/tools/kill-matrix.sh kill9-foreground     kill9-foreground
#   ... force-stop-idle / kill9-idle / am-kill-background / trim-memory / emu-kill

# 4) 读证据（WAL/journal CRC 校验 + session 形状）
python3 android/tools/kill-matrix-report.py /tmp/p6-matrix/force-stop-foreground

# 5) reclaim 矩阵
adb -s emulator-5566 shell am start -W -n com.phonedsh.probe/.MainActivity --es pdsh.secure.op put --es pdsh.secure.value 00112233…
adb -s emulator-5566 shell am start -W -n com.phonedsh.probe/.MainActivity --es pdsh.secure.op get
adb -s emulator-5566 shell locksettings set-pin --old 1234 5678        # C1b
adb -s emulator-5566 shell bmgr backupnow com.phonedsh.probe          # C4

# 6) 删 AVD
adb -s emulator-5566 emu kill; avdmanager delete avd -n pdsh-p6-5566
```

## 5. 没做的 / 做不了的

| 项 | 为什么 |
| --- | --- |
| 真掉电测试 | 无真机台架；模拟器是 QCOW2 + QEMU，`adb emu kill` 是虚拟机终止，不是给存储断电（决策记录 §3） |
| 真实 LMK 杀 | 模拟器上 `send-trim-memory` 只投递回调（实测 pid 不变），没有可靠办法触发 lmkd 杀进程；用后台 `am kill` 作为同类证据并明确标注 |
| OEM 查杀（华为 PowerGenie / 小米省电 / OPPO Athena） | 只在真机存在 |
| StrongBox/TEE 下的 C1 复跑 | 模拟器 `level=SOFTWARE` |
| 六小时后台 / FGS 超时 | 需要真后台时长 |
| BUG-1 的修复 | `android/core` 与 `spec/` 在本车道写权限外 |
