<!-- SPDX-License-Identifier: MIT -->
# P23 证据：按物理内存选 budgets 档位，超档写入被拒（2026-11-01）

本车道修的是「契约按内存分了档，实现一档都没选」：`spec/v1/budgets.md:95-97` 要求
**每次 boot 按物理内存上限选一次档**，`budgets.md:104` 给出 `Single file` 的逐档值
（256 / 128 / 48 / 32 / 16 MiB），而 Android 从未读过 `ActivityManager.MemoryInfo.totalMem`，
`:dsh` 里 host 的 `single_file_limit` / `VFS_REFUSED` 一直标着 not-implemented，
Worker 只能落到它自己的 8 GiB 默认 128 MiB。后果已由另一条车道实测：2 GB 的 AVD
（属 `≤ 3 GiB` 档，单文件应 16 MiB）**仍收到 128 MiB 的文件**，写入成功，恢复时 OOM。

- 设备：自建 AVD `p23-5590`（`hw.ramSize=2G`，端口 **5590**）与 `p23-5592`
  （`hw.ramSize=6144`，端口 **5592**），均为 `system-images;android-35;google_apis;arm64-v8a`、
  pixel_6、4 核，`-no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect`。
- 清理：实验结束 `adb emu kill` + `avdmanager delete avd -n p23-5590|p23-5592`。
- 探针：`SERIAL=emulator-5590 bash /tmp/probe.sh …`（真实 deepseek 模型）与
  `/tmp/p23-turn.sh`（脚本化上游，把唯一一次工具调用固定成写大文件，避免模型输出随机性）。

## 1. 档位表（逐档，`budgets.md` 行号）

`budgets.md:95-97`：档位在每次 boot 从物理内存上限选一次；8 GiB 行是默认；上限 < 8 GiB 时用更低的行；
12 GiB 行只在 ≥ 12 GiB 时适用。`MB`/`MiB` 都是 1 048 576 字节。

| 行 | totalMem 阈值 | Single file（`budgets.md:104`） | Single file host max（:105） | Engine heap（:101） | VFS logical（:102） | workspace/sessions/tmp（:103） | WASI hot（:106） | App process（:107） | Sub-agents（:110） |
|---|---|---|---|---|---|---|---|---|---|
| 12 GiB | ≥ 12 GiB | 256 MiB | 256 MiB | 832 MB | 768 MB | 576/96/96 MB | 640 MB | 540 MB | ≤ 2（thermal fair 1） |
| 8 GiB（默认） | ≥ 8 GiB 且 < 12 GiB | 128 MiB | 128 MiB | 448 MB | 388 MB | 288/50/50 MB | 260 MB | 230 MB | ≤ 2（fair 1） |
| 6 GiB | ≥ 6 GiB 且 < 8 GiB | 48 MiB | 128 MiB | 256 MB | 200 MB | 120/40/40 MB | 200 MB | 140 MB | ≤ 2（fair 1） |
| 4 GiB | ≥ 4 GiB 且 < 6 GiB | 32 MiB | 32 MiB | 192 MB | 144 MB | 80/32/32 MB | 144 MB | 120 MB | ≤ 1 |
| ≤ 3 GiB | < 4 GiB | 16 MiB | 16 MiB | 144 MB | 96 MB | 48/24/24 MB | 96 MB | 100 MB | ≤ 1 |

其它随档位变化的量：`Peak` ≤ 上限的 50%（:108）；`video/` 配额 512 MiB / 384 / 256 / 192 MiB
（`budgets.md:158`）；恢复目标是 `a + k·MB`，与档位无关（:132-133）。

`single_file_limit` 的取值规则：`budgets.md:120-123` —— host 可在 **16 MiB … 256 MiB** 之间设置；
4 GiB 与 ≤ 3 GiB 行**锁死在各自默认值**，8/6 GiB 行最高 128 MiB，12 GiB 行最高 256 MiB；
越界值**钳制，绝不启动失败**。

## 2. `VFS_REFUSED` 还是 `EFBIG`？

两个都对，但**不在同一层**：

| 位置 | 原文 | 结论 |
|---|---|---|
| `channel.md:264-268` | "The worker VFS refuses a post-write file above `single_file_limit` with **`EFBIG`** and emits no VFS_MUT" | Worker 侧错误码 = `EFBIG`（用户/工具看到的错误） |
| `channel.md:236` | "For `code = VFS_REFUSED`, `path`/`limit`/`reason` are also required … the **host budget check** for a mutation that would grow a file past `single_file_limit`" | 线上帧 = `ERROR VFS_REFUSED`（host 预算拒绝） |
| `channel.md:298` | "A host budget refusal sends the same frame … it appends nothing, leaves `expected_mseq` unchanged … never treats either refusal as a connection error" | host 拒绝不是协议错误、不关连接、不吃 mseq |
| `channel.md:362` | `VFS_REFUSED` … "consumes no mseq, and is a diagnostic" | 不关连接 |

所以：**Worker 侧 `EFBIG`、wire 侧 `VFS_REFUSED`**。本车道两层都实现，设备上先命中 Worker 的 `EFBIG`
（契约首选路径，字节根本不进 WAL），host 的 `VFS_REFUSED` 是 Worker 拿不到/忽略环境变量时的兜底。

## 3. 改了什么

| 文件 | 改动 |
|---|---|
| `android/dsh/src/main/kotlin/com/phonedsh/dsh/host/HostBudgetTier.kt`（新增） | 档位选择：`forTotalMemory(total)` → `ControllerBudgets.forTotalMemory`（阈值只有 `:controller` 一个 owner）；`readTotalMemoryBytes(context)` 读 `ActivityManager.MemoryInfo.totalMem`；`forDevice(context)`；`workerEnvironment(total)` 产出 `PDSH_SINGLE_FILE_LIMIT_BYTES`；`UNMEASURED` = `≤ 3 GiB` 行（16 MiB）。读不到（`totalMem == 0`）与「从未测量」（构造函数默认值）**是同一个事实，必须同一个答案**：都取最小行，绝不因为「没量到」放大配额。 |
| `android/dsh/.../VfsSink.kt` | 新增 `singleFileLimitBytes` 参数（默认 §4 默认行）；`append()` 在结构校验之后、WAL 之前按 `append_from + data`（完整写则 `data`）判上限；超限 → 一条 `VFS_REFUSED`（`path`/`limit`/`reason=file-too-large`/`mseq`/`accepted_bytes`/`ref_seq`，`closeConnection=false`），不写 WAL、不动 `nextMseq`。 |
| `android/dsh/.../PhoneDshHost.kt` | 新增 `deviceBudgets: ControllerBudgets = HostBudgetTier.UNMEASURED`（最小行，不是 8 GiB 行）；传给 `VfsSink`；`logBoot()` 打印 `budget tier: … single_file_limit: …`。 |
| `android/app/.../ProbeEngineViewModel.kt` | 组合根**测量一次**：`deviceBudgets = HostBudgetTier.forDevice(application)`；同一值进 Worker env 与 `DefaultPhoneDshHost`；init 打印 `device memory: totalMem=…` + 选中行。 |
| `android/app/.../ProbeLaunchConfig.kt` | `workerEnvironment(modelProxyMounted, singleFileLimitBytes)` 把 `PDSH_SINGLE_FILE_LIMIT_BYTES` 放进 `pageParams["env"]`（`WorkerEnvironment` 逐字合并到 `process.env`）。 |
| `HostChannel.kt` / `HostExec.kt` | **仅头部注释**：删掉 "not-implemented: host `single_file_limit` / `VFS_REFUSED`"，改为指向 `HostBudgetTier`/`VfsSink`。无逻辑改动。 |
| `android/dsh/src/test/.../HostBudgetTierTest.kt`（新增）、`VfsBudgetRefusalTest.kt`（新增） | 档位/边界/环境变量；host→channel→sink→codec 全链路 `VFS_REFUSED`；sink 边界（恰好等于上限合法，多 1 字节拒绝）；完整写 `accepted_bytes=0`。 |

**为什么通告用环境变量而不是 HELLO caps**：`channel.md` §4.1 的 HELLO 没有单文件上限成员，且
"Other capability strings are reserved"（只允许 `channel/1`、`wal/1`、`exec/1`、`accelerator:<name>`）。
Worker 侧本来就把这个环境变量当成 host 的发布通道：
`plugins/wasi-toolbox/src/limits.ts:43-44` 写着 "Environment name the host uses to publish its
`single_file_limit` (D4)"，entry 会把它钳制进 16 MiB…256 MiB 再在 VFS boot 前应用。

## 4. 设备证据（原始输出）

### 4.1 两台设备的档位（`adb logcat -s PDSHHost`）

```
# emulator-5590 (hw.ramSize=2G, MemTotal 2 531 992 kB)
I PDSHHost: device memory: totalMem=2592759808 bytes; budget tier: <= 3 GiB; single_file_limit: 16777216 bytes (16 MiB); Worker env PDSH_SINGLE_FILE_LIMIT_BYTES=16777216
I PDSHHost: budget tier: <= 3 GiB (budgets.md §4), single_file_limit: 16777216 bytes (16 MiB), workspace: 50331648 bytes, VFS logical: 100663296 bytes, engine heap: 150994944 bytes

# emulator-5592 (hw.ramSize=6144, MemTotal 6 069 180 kB)
I PDSHHost: device memory: totalMem=6214840320 bytes; budget tier: 4 GiB; single_file_limit: 33554432 bytes (32 MiB); Worker env PDSH_SINGLE_FILE_LIMIT_BYTES=33554432
I PDSHHost: budget tier: 4 GiB (budgets.md §4), single_file_limit: 33554432 bytes (32 MiB), workspace: 83886080 bytes, VFS logical: 150994944 bytes, engine heap: 201326592 bytes
```

注意 6 GB 的 AVD 报 `totalMem = 5.79 GiB`，按 `budgets.md:95-96`「上限低于 8 GiB 时用更低的行」
落在 **4 GiB 行**（32 MiB），不是 6 GiB 行——这是阈值语义，不是偏差。

### 4.2 核心验收：2 GB 设备上超档写入被拒（原始 tool result）

探针（脚本化上游）让 Worker 的 `bash` 工具连续追加 16 × 1 MiB 后继续追加，第 17 次越界：

```
append_1 exit=0
append_2 exit=0
...
append_16 exit=0
-rw-r--r-- 1 user user 16777216 Nov  1 13:22 /dsh/workspace/p23-big.bin
loop_done
[stderr]
EFBIG: File too large: /dsh/workspace/p23-big.bin would be 17825792 bytes; a file is limited to 16777216 bytes (16 MiB), '/dsh/workspace/p23-big.bin'
```

文件停在 **16 777 216 字节（16 MiB）**，没有写进去再等恢复失败。消息里的
`16777216 bytes (16 MiB)` 是 `limits.ts` 的 `formatByteLimit` 渲染的，即 Worker 真的用了 host
发布的值（Worker 内置默认是 128 MiB）。

### 4.3 同一操作在 6 GB 设备上（A/B 对照）

```
append_1 exit=0
...
append_20 exit=0
-rw-r--r-- 1 user user 20971520 Nov  1 13:23 /dsh/workspace/p23-big.bin
loop_done
```

20 MiB 全部写入成功：它高于 2 GB 档的 16 MiB、低于 4 GiB 档的 32 MiB。两台设备的档位确实不同。

> 说明：设备上先命中 **Worker 的 `EFBIG`**（`channel.md:268`）是契约首选路径；host 的
> `VFS_REFUSED` 兜底由 `VfsBudgetRefusalTest` 在 JVM 上以真实 Rust codec + 真实 `HostChannel`
> 覆盖（下面 5.1），因为要在设备上同时触发兜底，必须故意让 Worker 的 env 与 host 的档位不一致。

## 5. 单测与反向验证

### 5.1 新增单测

- `HostBudgetTierTest`（6 个）：逐档阈值（含「恰好等于阈值」与「差 1 字节」）、`Single file` 逐档值
  （256/128/48/32/16 MiB）、未知上限 → 最小行、**「未测量」默认值也 = 最小行，且与 `totalMem = 0`
  给出同一行**、Worker env 发布值，以及「2 GiB 设备不得拿到 128 MiB 默认」这条反向锚点。
  （7 个测试。）
- `VfsBudgetRefusalTest`（2 个）：
  1. **全链路**：`DefaultPhoneDshHost(deviceBudgets = ≤ 3 GiB 行)` → `HostChannel` → `VfsSink`
     → Rust codec。`append_from = 16 MiB` + 1 字节 → 只回一条 `ERROR VFS_REFUSED`
     （`path`/`limit=16777216`/`reason=file-too-large`/`ref_seq`/`mseq=42`/`accepted_bytes=16777216`），
     WAL 一条都没写、没有 level-1 ACK、连接未关闭、admission 仍 open；随后**同一个 mseq 42** 的合法
     后缀被接受并 ACK（证明拒绝没有吃掉 mseq）。
  2. **未测量默认值**：`DefaultPhoneDshHost(...)` **不传** `deviceBudgets`（真正走构造函数默认值，
     不是把常量再传一遍）→ `append_from = 16 MiB` 的后缀被接受，`append_from = 16 MiB` + 1 字节
     被 `VFS_REFUSED`（`limit = 16777216`）。默认值若改回 8 GiB 行，这条 16 MiB + 1 的写会被接受，
     测试即红。
  3. **sink 边界**：limit 1024 时，恰好 1024 字节的完整写被接受；1025 字节被拒，
     `accepted_bytes = 0`（完整写）、`mseq` 回显、`closeConnection = false`。
  （3 个测试。）

### 5.2 反向验证 A：把档位选择改成「总是最高档」

把 `HostBudgetTier.forTotalMemory` 临时改成 `ControllerBudgets.forTier(MemoryTier.GIB_12)`：

```
HostBudgetTierTest > the worker environment publishes the selected single file limit FAILED
HostBudgetTierTest > tier thresholds are the budgets md 4 rows FAILED
HostBudgetTierTest > a two GiB device is not handed the 8 GiB default FAILED
HostBudgetTierTest > an unknown ceiling takes the smallest row FAILED
HostBudgetTierTest > the unmeasured default is the smallest row, not the 8 GiB default FAILED
HostBudgetTierTest > single file limit is the budgets md 4 single file row FAILED
HostBudgetTierTest > a device just under a threshold takes the row below it FAILED
6 tests completed, 6 failed
BUILD FAILED
```

还原后同一命令 `BUILD SUCCESSFUL`。

### 5.3 反向验证 B：只把「未测量」默认值改回 8 GiB 行

`UNMEASURED` 保持 16 MiB，只把 `PhoneDshHost.deviceBudgets` 的默认值改成
`ControllerBudgets.forTier(MemoryTier.GIB_8)`：

```
VfsBudgetRefusalTest > aHostWithNoMeasuredTierRefusesAtTheSmallestRow FAILED
10 tests completed, 1 failed
BUILD FAILED
```

**只有**那条端到端默认值测试失败——证明它钉的是构造函数默认值本身，而不只是那个常量。
还原后 `BUILD SUCCESSFUL`。

### 5.4 反向验证 C：`UNMEASURED` 改回 8 GiB 行

```
HostBudgetTierTest > the unmeasured default is the smallest row, not the 8 GiB default FAILED
VfsBudgetRefusalTest > aHostWithNoMeasuredTierRefusesAtTheSmallestRow FAILED
10 tests completed, 2 failed
BUILD FAILED
```

## 6. 门禁

```
bash scripts/ci/check.sh --only phone-android-structure,phone-android-tests
  PASS  phone-android-structure     3s
  PASS  phone-android-tests       28s
TOTAL  1450 tests, 0 failing   (11 modules; :dsh 189)
```

`android/tools/structure_check.py` 11 项全 PASS，`test_structure_check.py` 18 tests OK。

## 7. 与 P22 的边界

P22 在 `:dsh` 里修通道自愈，同一工作树并发改 `HostChannel.kt` / `PhoneDshHost.kt`。本车道**没有**
碰通道生命周期、状态机、seq 校验或 sink 的 open/close 语义；在 `HostChannel.kt` / `HostExec.kt`
里只改了两处**头部注释**（删掉 not-implemented 声明）。其余改动文件为
`HostBudgetTier.kt`（新）、`VfsSink.kt`（新增参数 + 拒绝分支）、`PhoneDshHost.kt`（新增参数 + 传参 + 一行 boot 日志）、
`android/app` 两个组合根文件与两个新测试文件。并发期间观察到 P22 的 `ChannelLossExitTest.kt`
一度未编译，本车道等其修好后跑完整 `:dsh` 套件（189 tests）。
