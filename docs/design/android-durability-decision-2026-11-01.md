<!-- SPDX-License-Identifier: MIT -->
# 决策记录：Android 掉电持久化（R1）— 降级为「进程被杀不丢 + 尾部可检出」

日期：2026-11-01 · 车道：P6（进程被杀矩阵 / 掉电决策 / reclaim token）
状态：**已决定（降级）** · 影响：`android/platform-android` 的 `Durability.level()` 返回值、产品文案、回执 §4.2/§5

## 1. 决定

**不保留 level-2（「掉电最多丢最后一个纪元」）承诺。** 本轮把 Android 的持久化承诺降级为：

> **进程被杀不丢**（level 1，已实测）；**掉电/崩溃留下的不完整尾部可被检出并记录**（已实测）；掉电时最多丢什么**不作承诺**。

三条推论：

1. `AndroidDurability.level()` 继续返回 `DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED`，`supportsLevel2Claim()` 为 false，`:controller` 把它按 level 1 处理（代码现状正确，不改）。
2. **机制不动**：D18 的三步 fsync 顺序（文件 fsync → 目录 fsync → manifest 原子替换）原样保留，测试原样保留。本决策只收窄**对外承诺**，不回退共享 spec 语义（与 `spec/platform/whitelist.json` 里 `platform.fsync-epoch-close` 的 rationale 一致）。
3. 产品文案里禁止出现「掉电最多丢最后一个纪元」。允许的说法只有「进程被杀不丢」和「不完整的尾部会被检出并记录」。

## 2. R1 问的是什么

- iOS 基线用 `fcntl(F_FULLFSYNC)`，它把数据送到**设备的非易失介质**；Android 只有 `fdatasync/fsync`，只保证数据到达**存储栈**，之后是否在掉电时幸存取决于文件系统（f2fs/ext4）与设备 write cache（UFS/eMMC 的缓存与 FTL）。
- `spec/v1/wal.md` §5.2 / D7：level-2 是「纪元关闭记录 + 该纪元写过的每个段 `F_FULLFSYNC` + 目录 fsync」之后发出的 ack-2，承诺「掉电最多丢最后一个纪元」。
- `spec/platform/whitelist.json` 的 `platform.fsync-epoch-close` 明确写着：这条在 Android 上「**必须按设备等级重新实测**」，「level-2 是实测承诺而不是机制保证」。
- 所以 R1 不是「代码怎么写」，而是「**本轮有没有台架能实测**」。

## 3. 台架可用性判断：不可用

| 判据 | 实测/事实 | 结论 |
| --- | --- | --- |
| 真机 | `adb devices -l` 只有 `emulator-5556/5558/5560/5564/5566`，无 USB 设备 | 无真机台架 |
| 模拟器存储 | AVD 数据分区是宿主上的 **QCOW2**（`file userdata-qemu.img` → `QEMU QCOW2 Image (v3)`） | 没有 UFS/eMMC、没有设备 write cache、没有 FTL |
| fsync 语义 | guest `fsync` → virtio flush → QEMU `fsync` 宿主文件；宿主页缓存/回写策略参与，且**宿主文件系统不是被测对象** | fsync 是否「到达介质」在这里无法区分 |
| `adb emu kill` | 杀的是**模拟器进程/虚拟机**，不是给存储设备断电 | 不能代表掉电；也不能证明「fsync 之后的数据一定在介质上」 |
| 样本代表性 | 结果只说明「这台 Mac 的 QCOW2 + QEMU」，不迁移到任何真实设备类 | 实测结果不可用作设备等级结论 |

**结论：本轮无法论证 level-2。** 按任务要求选「降级 + 文档化」，不拿进程级 kill 冒充掉电。

## 4. 本轮实际测到的证据

完整矩阵与原始日志见 [android-p6-kill-matrix-2026-11-01.md](../receipts/android-p6-kill-matrix-2026-11-01.md)。摘要：

### 4.1 进程被杀（5 种杀法 × 时机，全部 level-1）

`am force-stop`、`kill -9`（前景回合中 / 空闲）、`am kill`（后台）、`send-trim-memory` 后的后台 kill：杀前/杀后/恢复后三步，WAL 记录数、journal 记录数、目标 session 行数**逐项相等**，没有 torn tail，没有半截记录，session 的 `turn/end` 有无与杀法一致（回合中杀 → 无 `turn/end`；空闲杀 → 有）。恢复后 `wal/1: on`，HELLO 的 `next_mseq/acked_mseq` 由恢复结果给出。

### 4.2 不完整尾部可检出（两条独立证据）

- **注入**：向最后一个段尾部追加 16 字节伪记录 → 启动时
  `WAL_TORN_TAIL_TRUNCATED boot=8a3f… segment=00000025.000000.xlwal keep_len=14266 dropped_bytes=16 previous_len=14282`，
  截断后 `wal/1: on`，前缀完整，UI 出现「WAL 尾部被截断」横幅。
- **真实**：`adb emu kill` 之后，被杀回合的 `session.v4.jsonl` 最后一行是 **NUL 填充的半截行**（5 行，第 5 行解析失败），tool-journal 同样以 NUL 结尾。任何读者都能检出「这条尾巴不完整」。

### 4.3 掉电类事故暴露的真问题（见 §6）

`adb emu kill`（本轮能拿到的最接近掉电的终止方式）之后：WAL 目录里留下两个 **0 字节段文件**（`00000024`、`00000025`），恢复按 `wal.md` §7.2/§10 判为 `WAL_CORRUPT` → `wal/1 off` → Worker 以 `PROTO_MISMATCH` 拒绝启动 → **工作区不可用**。

这比「丢最后一个纪元」严重得多：**不是丢尾部，而是整个工作区报废**。所以即便将来台架证明「掉电最多丢最后一个纪元」，也必须先修掉这条恢复路径，level-2 才谈得上可用。

## 5. 被否决的替代方案

| 方案 | 为什么否决 |
| --- | --- |
| 以「机制已经有 D18 fsync 顺序」为由保留 level-2 | whitelist 明说 level-2 是**实测**承诺；机制存在不等于设备 write cache 下成立 |
| 在模拟器上跑「掉电」并当证据 | 见 §3：模拟器掉电是虚拟机终止，测的是 QEMU/宿主 FS，不是设备 |
| 多 sync 几次 / 调大 fsync 频率 | 改不了设备 write cache 的语义，只是降低概率，构成隐性承诺 |
| 先不写文案，代码里留着 `MEASURED` 分支 | 分支已存在但无人返回它；风险在于别处误用，已在 `supportsLevel2Claim()` 单点收口 |

## 6. 与本次事故相关的未修问题（不在本车道写权限内）

**BUG-1（阻断级，:core / spec）**：未列入 manifest、且**读不出 header** 的段（0 字节）被判 `WAL_CORRUPT` → `Failed`，恢复永久失败，无产品内修复路径。
- 实测：`adb emu kill` 后出现 `00000024`/`00000025` 两个 0 字节文件；删除这两个文件后同一工作区恢复成功（`next_mseq=438, acked_mseq=437`），说明**保留前缀完好**，损坏仅由这两个空文件引起。
- 建议（spec 拥有者定夺）：把「未列入 manifest 且长度 < 40 字节（连 header 都没有）的段」按「无任何记录、可丢弃」处理，而不是 `WAL_CORRUPT`；或在 `Failed` 上给出显式的「丢弃该段并恢复前缀」用户动作。这两条都动 spec/` :core`，本车道只报告。

**BUG-2（已修，:app）**：`WAL_CORRUPT` 之后宿主 HELLO 缺 `wal/1`，Worker `PROTO_MISMATCH` 拒绝启动，但探针屏仍显示「运行中」且无横幅 —— 用户无法知道工作区已死。已加 `wal/1` 缺失横幅（`ProbeRecovery.raiseWalUnavailable` + `ProbeScreen.RecoveryBanner`），并用注入 0 字节段复现验证。

## 7. 什么条件下可以把承诺改回 level-2

需要一台**真机** + 可控断电（继电器/USB 电源开关），并满足：

1. 覆盖两类文件系统（f2fs、ext4）与至少两类 write cache 配置（开/关 UFS cache）；
2. 每类 ≥20 次随机点断电，断电点落在纪元写入过程中；
3. 验收：每次冷启动都能恢复出一个合法前缀；丢失 ≤ 最后一个已关闭纪元；不出现 `WAL_CORRUPT`（含本次的 0 字节段形态）；`tool-journal` 能指出缺失的步；
4. 记录设备型号、内核、文件系统、cache 模式、复位方式，作为「设备类」结论的适用范围；
5. 在此之前 `Durability.level()` 不得返回 `LEVEL_2_POWER_LOSS_MEASURED`。

## 8. Open questions

- BUG-1 的修复归属：改 `wal.md` §7.2/§10（把「空段」与「header 损坏」分开），还是在 app 层给「丢弃不可读段」的显式动作？两者都需要 spec 拥有者拍板。
- 0 字节段的**产生根因**：段文件创建（dirent）已持久而 header 数据页丢失，是否需要「创建段时先写 header 并 fsync 目录」？这会让每次建段多一次 fsync，属性能/复杂度权衡。
- 探针屏的横幅优先级：`WAL_UNAVAILABLE`(4) > `SECURE_UNREADABLE`(3) > `WAL_TRUNCATED`(2) > `TURN_INTERRUPTED`(1) 是本轮定的；产品面是否需要同时显示多条？
- 产品文案落在 `:lib`（只读车道），本轮只在探针屏 footer 加了诚实声明，正式文案需要 UI 车道同步。
