<!-- SPDX-License-Identifier: MIT -->
# 决策记录：Android 掉电持久化（R1）— 降级为「进程被杀不丢 + 尾部可检出」

日期：2026-11-01 · 车道：P6（进程被杀矩阵 / 掉电决策 / reclaim token）
状态：**已决定（降级，不推翻）** · 影响：`android/platform-android` 的 `Durability.level()` 返回值、产品文案、回执 §4.2/§5

> **修订 2026-11-01（L42 复核）**：决定不变，**论证换地基**。原稿的论据主要是「本轮没有台架」
> （测量缺口）；§3.1 补上两处遗漏——它没有论证「做不到」，而且漏掉了**不需要台架就能测、
> 且今天就是红的那一层**（恢复层把合法的掉电残缺判成 `WAL_CORRUPT`）。§2 的一处措辞已更正，
> §4.4 补了 3 轮可复现实验，§6/§7/§8 按新证据重写。完整验证计划见
> [android-power-cut-verification-plan-2026-11-01.md](android-power-cut-verification-plan-2026-11-01.md)。

## 1. 决定

**不保留 level-2（「掉电最多丢最后一个纪元」）承诺。** 本轮把 Android 的持久化承诺降级为：

> **进程被杀不丢**（level 1，已实测）；**掉电/崩溃留下的不完整尾部可被检出并记录**（已实测）；掉电时最多丢什么**不作承诺**。

三条推论：

1. `AndroidDurability.level()` 继续返回 `DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED`，`supportsLevel2Claim()` 为 false，`:controller` 把它按 level 1 处理（代码现状正确，不改）。
2. **机制不动**：D18 的三步 fsync 顺序（文件 fsync → 目录 fsync → manifest 原子替换）原样保留，测试原样保留。本决策只收窄**对外承诺**，不回退共享 spec 语义（与 `spec/platform/whitelist.json` 里 `platform.fsync-epoch-close` 的 rationale 一致）。
3. 产品文案里禁止出现「掉电最多丢最后一个纪元」。允许的说法只有「进程被杀不丢」和「不完整的尾部会被检出并记录」。

## 2. R1 问的是什么

- iOS 基线用 `fcntl(F_FULLFSYNC)`，它是「把设备写缓存刷到非易失介质」的显式调用；Android 没有这条 ioctl，只有 `fsync/fdatasync`。
- **更正（2026-11-01）**：原稿写的是「`fdatasync` 只保证数据到达存储栈」，这偏保守。Linux 的 `fsync/fdatasync` 在设备声明了 volatile write cache 时会走块层 flush（`blkdev_issue_flush` → `REQ_OP_FLUSH`），ext4 在 `barrier` 开启时就是这么做的（见 `platform-android` 的实现与 `spec/platform` rationale）。所以 Android 的原语**不是「半个 fsync」**，真正的缺口是：
  1. 设备固件可能**收下 flush 却不刷**（廉价 eMMC/UFS 的已知失效模式）；
  2. 挂载可能把 barrier 关掉（`nobarrier`/`barrier=0`）；
  3. 文件系统自己可能有 fsync 缺陷（f2fs 到 2026-03 还有「fsync 不写 node folio 导致丢数据」的补丁）。
- 这三条都**无法从 API 侧证明**，只能按设备类实测——所以「level-2 是实测承诺而不是机制保证」这个结论成立，但理由要改成「**设备是否兑现 flush 不可证**」，而不是「我们只有到达存储栈的原语」。
- `spec/v1/wal.md` §5.2 / D7：level-2 是「纪元关闭记录 + 该纪元写过的每个段 `F_FULLFSYNC` + 目录 fsync」之后发出的 ack-2，承诺「掉电最多丢最后一个纪元」。
- `spec/platform/whitelist.json` 的 `platform.fsync-epoch-close` 明确写着：这条在 Android 上「**必须按设备等级重新实测**」，「level-2 是实测承诺而不是机制保证」。
- 所以 R1 不是「代码怎么写」，也不是「有没有 fsync 原语」，而是「**本轮有没有办法证明：这类设备兑现 flush，且我们的恢复层接得住掉电形状的残缺**」。后者**不需要台架**（见 §3.1）。

## 3. 台架可用性判断：不可用

| 判据 | 实测/事实 | 结论 |
| --- | --- | --- |
| 真机 | `adb devices -l` 只有 `emulator-5556/5558/5560/5564/5566`，无 USB 设备 | 无真机台架 |
| 模拟器存储 | AVD 数据分区是宿主上的 **QCOW2**（`file userdata-qemu.img` → `QEMU QCOW2 Image (v3)`） | 没有 UFS/eMMC、没有设备 write cache、没有 FTL |
| fsync 语义 | guest `fsync` → virtio flush → QEMU `fsync` 宿主文件；宿主页缓存/回写策略参与，且**宿主文件系统不是被测对象** | fsync 是否「到达介质」在这里无法区分 |
| `adb emu kill` | 杀的是**模拟器进程/虚拟机**，不是给存储设备断电 | 不能代表掉电；也不能证明「fsync 之后的数据一定在介质上」 |
| 样本代表性 | 结果只说明「这台 Mac 的 QCOW2 + QEMU」，不迁移到任何真实设备类 | 实测结果不可用作设备等级结论 |

**结论：本轮无法论证 level-2。** 按任务要求选「降级 + 文档化」，不拿进程级 kill 冒充掉电。

### 3.1 §3 证明的是「测量缺口」，不是「能力缺口」（2026-11-01 补）

上面这张表只能推出一个结论：**这台模拟器不能当设备类台架**。它推不出「level-2 做不到」。两者必须分开：

| | 缺口 | 缺的是什么 | 没有台架能不能补 |
| --- | --- | --- | --- |
| **测量缺口** | 没有真机 + 可控断电，无法给出「某设备类最多丢最后一个纪元」的**设备类结论** | 台架 | **不能** |
| **机制缺口** | 恢复层把「合法的掉电残缺」判成 `WAL_CORRUPT`（BUG-1），验收判据 §7 的「不出现 `WAL_CORRUPT`」直接不成立 | 排序修复 + spec 决策 | **能**，而且今天就是红的（§4.4） |

§3 的表其实只否掉了一件事：**「把模拟器当设备类台架」**。它没有否掉另一件事：
`adb emu kill` 是**有效的「页缓存丢失」切割**——guest 页缓存没了、ext4 走 journal replay、
应用看到的就是磁盘上剩下的字节。这正是 L1 排序层（文件 fsync / 目录 fsync / rename 顺序）
要验的东西；它不能验的只有 L2（设备 write cache / FTL 是否兑现 flush）。
本轮没有做这个区分，于是把「能验的一半」和「不能验的一半」一起丢掉了。

判定 `adb emu kill` 不是空转的实测证据（§4.4）：**不 fsync 就丢**——1 MiB 与 4 KiB 的写入，
在切割后一律以 `size=0` 回来（N/N3/J/J3/U3/D2/D3）；**fsync 过的一个不丢**（G/H/G3/Q）。
如果这个切割是假的，两组不会有差别。

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

### 4.4 0 字节段不是「没台架所以不知道」，是「现在就能复现」（2026-11-01 补）

在自建 AVD（`l42probe`，android-35 google_apis，端口 5684）上做了 3 轮切割：r1 是**对照组**
（写入后 ≥30 s、约 1 min 才切），r2/r3 在写入后 **0.24–0.3 s** 切；每轮重启同一 userdata，
让 ext4 走 journal replay，再逐字节比对。
`/data` 是 ext4，挂载 `data=ordered, delalloc, barrier, auto_da_alloc, commit=5`，
`/sys/block/dm-44/queue/write_cache` = `write back`。完整脚本与判据见
[验证计划 §4](android-power-cut-verification-plan-2026-11-01.md)。

| case（切割时机见备注） | 掉电后 | 实测 |
| --- | --- | --- |
| 写 1 MiB，不 fsync（**r1 对照组：≥30 s 后才切**） | 允许丢 | **size=0** → 时间不会替你做 fsync，模拟器比真机更狠 |
| 写 1 MiB，不 fsync（紧切） | 允许丢 | **size=0**（N/N3） |
| 写 1 MiB，只 `fsync` 目录 | 不该活 | **size=0**（J/J3）→ 目录 fsync 不能替代文件 fsync |
| 写 1 MiB，`fsync` 文件（含两级新建目录、目录从不 fsync） | 必须活 | **sha256 一致**（G/H/G3/Q） |
| **先建空文件 + `fsync` 目录，再写 4096 B 负载、不 fsync** | 允许丢 | **size=0** ← **就是 §4.3 的 0 字节段** |
| 建空文件 → 等 7 s 让日志提交 → 写负载（不 fsync），随后同轮别的文件 fsync | 边界 | **size=4096（活了）** ← 被别人的 fsync 顺带提交（D1） |

五条结论，都会改变本决策的论证：

1. **0 字节段的成因类别是「写—提交顺序」，不是设备**：只要 inode 以 `size=0` 被提交、而 payload
   的写入发生在**之后**且没有 fsync，崩溃后就是「文件在、0 字节」。这与 UFS/eMMC 的 write cache
   无关——**台架修不了它，模拟器今天就能复现它**。（严格说：K3 是我们**构造**出这个窗口，
   不是从应用侧抓到「create 与 header write 之间真的跨了一次日志提交」；见 §8。）
2. **`createSegment` 现在正好是这个形状**：`WorkspaceLog.kt:1274` 用 `CREATE_NEW` 建段、
   写 40 B header（`WalSegmentHeader.BYTES = 40`），**不 fsync**；header 要等到纪元关闭
   （§5.2 第 3 步）才被刷——窗口 30–60 s。§8 里「是否需要建段时先写 header 并 fsync 目录」
   这个问题的答案是：**需要在写完 header 后 fsync 文件**（成本：每纪元 1 次；目录 fsync 可以省，
   因为 `fsync(file)` 会提交同一事务里的新 dirent，实测 G3/Q 已证）。
3. **`fsync(dir)` 单独用是无效的安全感**（J/J3）：D18「先文件、后目录」的顺序是承重的。
4. **单次「活下来了」不算证据**：同一轮里别的文件的 fsync 会把整条日志提交，把之前的脏数据
   一起带下去（D1 就是这样活下来的）。§7.2 的「≥20 次随机点」不是形式主义。
5. **模拟器只可证伪、不可证实**：r1 里 ≥30 s 没 fsync 的数据仍然全丢，而真机上 30 s 脏页回写
   通常已经把它写下去了。所以「模拟器上活下来」不能推出「真机上活下来」；反向的「模拟器上丢了」
   也不必然意味着真机丢。这一层只能用来验**排序是否自洽**，不能用来给**设备类**下结论。

所以「本轮无法论证 level-2」这句话要拆成两句：
**设备类结论确实无法给出**（§3 成立）；**但 level-2 的机制半边今天就能测，而且今天不过**（§4.4）。

## 5. 被否决的替代方案

| 方案 | 为什么否决 |
| --- | --- |
| 以「机制已经有 D18 fsync 顺序」为由保留 level-2 | whitelist 明说 level-2 是**实测**承诺；机制存在不等于设备 write cache 下成立 |
| 在模拟器上跑「掉电」并把它当**设备类证据** | 见 §3：模拟器掉电是虚拟机终止，测的是 QEMU/宿主 FS，不是设备。注意这条**只否掉「设备类证据」**——同一套切割可以当**机制半边**证据，见 §3.1/§4.4 |
| 用「模拟器上活下来了」当 level-2 的充分条件 | 模拟器比真机更狠：真机 30 s 脏页回写能救回的东西，这里也会丢（§4.4 r1）。所以它只能证伪、不能证实 |
| 多 sync 几次 / 调大 fsync 频率 | 改不了设备 write cache 的语义，只是降低概率，构成隐性承诺 |
| 先不写文案，代码里留着 `MEASURED` 分支 | 分支已存在但无人返回它；风险在于别处误用，已在 `supportsLevel2Claim()` 单点收口 |

## 6. 与本次事故相关的未修问题（不在本车道写权限内）

**BUG-1（阻断级，:core / spec）**：未列入 manifest、且**读不出 header** 的段（0 字节）被判 `WAL_CORRUPT` → `Failed`，恢复永久失败，无产品内修复路径。
- 实测：`adb emu kill` 后出现 `00000024`/`00000025` 两个 0 字节文件；删除这两个文件后同一工作区恢复成功（`next_mseq=438, acked_mseq=437`），说明**保留前缀完好**，损坏仅由这两个空文件引起。
- **成因类别（2026-11-01 补，可复现）**：不是「模拟器怪癖」，是「inode 以 `size=0` 提交、payload 后写且未 fsync」这一类写—提交顺序问题；`createSegment`（`WorkspaceLog.kt:1274`）建段后写 40 B header **从不 fsync**，正落在这个风险类里。§4.4 的 K3 用一条 shell 命令稳定复现了这个形状，**与设备 write cache 无关**。
  **诚实边界**：应用侧的确切窗口未定——K3 是我们构造的，不是从真实运行里抓到「create 与 header write 之间跨了一次日志提交」；也可能有 Java 缓冲层的成分（§8）。但无论哪种子情况，**下面第 1 条修复都能同时消掉**。
- 修复要两条一起（缺一仍是砖化路径）：
  1. **`:core`**：`createSegment` 写完 header 后 `fsync` 文件（每纪元 1 次；目录 fsync 可省，`fsync(file)` 已发布同一事务的 dirent）；
  2. **spec/`:core`**：把「未列入 manifest 且长度 < header（40 B）的段」按「无记录、可丢弃」处理，而不是 `WAL_CORRUPT`；或在 `Failed` 上给出显式的「丢弃该段并恢复前缀」用户动作。
- 只做 1 或只做 2 都能让 §4.4 的 K3 不再砖化，但**只有 1 能让「0 字节段」不再产生**——所以建议两条都做。

**BUG-2（已修，:app）**：`WAL_CORRUPT` 之后宿主 HELLO 缺 `wal/1`，Worker `PROTO_MISMATCH` 拒绝启动，但探针屏仍显示「运行中」且无横幅 —— 用户无法知道工作区已死。已加 `wal/1` 缺失横幅（`ProbeRecovery.raiseWalUnavailable` + `ProbeScreen.RecoveryBanner`），并用注入 0 字节段复现验证。

## 7. 什么条件下可以把承诺改回 level-2

原来的答案是「一台真机 + 可控断电」。补上 §4.4 之后，路径变成三段，**前两段不需要台架**；
顺序不能反，因为第 1、2 段的失败形态是设备无关的，台架只会更贵地复现同一件事。

**A. 机制（无台架，必须先做）**
1. `createSegment` 写完 header 后 fsync 文件（`WorkspaceLog.kt:1274`）；
2. 恢复层容忍「未列入 manifest 且 < 40 B」的段（BUG-1，spec 决策）；
3. 验收：§4.4 的 K3 形状掉电后不再出现 `WAL_CORRUPT`，`wal/1` 保持 `on`，前缀完整。

**B. 模拟器 crash 矩阵（无台架，可 CI 化）**
4. 在应用真实路径上（§5.2 五步之间）做 ≥20 次随机点 `adb emu kill`，每次冷启动验收：
   合法前缀 / 丢失 ≤ 最后一个已关闭纪元 / 无 `WAL_CORRUPT` / journal 能指出缺失步。
5. 这一层的结论只能写成「**机制半边通过**」，**不能**写成设备类结论（模拟器无 FTL、无设备 cache，
   切割点也不可控）。判据与命令见[验证计划 §4](android-power-cut-verification-plan-2026-11-01.md)。

**C. 真机台架（需要硬件）**
6. 覆盖两类文件系统（f2fs、ext4）与至少两类 write cache 配置（开/关 UFS cache）；
7. 每类 ≥20 次随机点断电，断电点落在纪元写入过程中；
8. 验收同 4，外加一条：**fsync 返回成功之后的数据一次都没丢**；
9. 记录设备型号、内核、文件系统、挂载选项、`queue/write_cache`、复位方式，作为「设备类」结论的适用范围；
10. 在此之前 `Durability.level()` 不得返回 `LEVEL_2_POWER_LOSS_MEASURED`。

**重新评估的触发条件**（命中任一条就重开本决策）：
- A 完成（BUG-1 修掉 + 建段 fsync 落地）→ 重跑 B，把结果补进本文件；
- B 连续 20 次全绿 → 把 P3 的 gate 从「等台架」改成「台架是最后一步」，并在回执里更新证据等级；
- 任何一台设备在 C 里出现「fsync 成功但数据丢」→ 该设备类**永久** `UNVERIFIED`，
  实测窗口写进 `spec/platform` 附录，**不**用其它设备类的结果外推；
- 产品文案若需要在 A 之前发布，仍只允许「进程被杀不丢 + 尾部可检出」。

## 8. Open questions

- **已答（2026-11-01）**：0 字节段的产生根因是「inode 先以 `size=0` 提交、payload 后写且未 fsync」的排序问题，
  已用 shell 序列稳定复现（§4.4 K3）；`createSegment` 正是这个形状。**不需要**「建段时再 fsync 目录」——
  `fsync(file)` 已把同一事务的 dirent 一起发布（G3/Q 实测）。
  残留不确定（两条）：① 应用侧 `write(2)` 是否还被 Java 缓冲层推迟——若被推迟，「建段 fsync」必须放在
  header 真正 `write` 之后；② K3 的窗口是我们构造的，真实运行里「create 与 header write 之间跨了一次
  日志提交」的概率没有被测过（`commit=5` 下每次建段约 1/5000 量级，未证实）。这两条都可由
  「建段即 fsync」直接绕过，不需要先测清楚。
- **BUG-1 的修复归属**：改 `wal.md` §7.2/§10（把「空段」与「header 损坏」分开），还是在 app 层给
  「丢弃不可读段」的显式动作？两者都需要 spec 拥有者拍板；建议两条都做（§6）。
- **新建段用哪种写法**：`CREATE_NEW + write header + fsync(file)`（每纪元 1 次 fsync），
  还是 `写临时名 + fsync + rename`（多一次 rename、但崩溃时连空文件都不会留下）。
  前者便宜、后者更干净；按 D18 的既有风格倾向前者，需要 `:core` 定。
- **模拟器切割的校准**：QEMU 的 cache 模式不在 argv 里，无法证明「模拟器的丢失窗口 ≥ 真机」。
  若要做成 CI gate，需要先补一个校准实验（同一脚本在真机上复跑，比较丢失分布）。
- **P3 gate 的证据分级**：验证计划 §4 的「机制半边通过」算不算 P3 的一条 gate？
  若算，`spec/platform/whitelist.json` 的 `evidence_level` 需要新增一档（`emulator-crash`），
  现在只有 `emulator-probe` / `device-gate` / `not-verified` / `spec-only`。
- **whitelist 的 `android_mechanism` 与实现不一致（需 spec owner）**：`platform.fsync-epoch-close` 写的是
  「fdatasync（必要时 fsync）」，实现用的是 `fsync`（`FileChannel.force(true)`）。方向是**更强**，不是漂移；
  但 `fdatasync` 不发布新建文件的 dirent——照着 whitelist 实现的人可能顺手把目录 fsync 也省掉。
  建议改成「`fsync`（文件与目录）；`fdatasync` 不作为等价物」，或在平台原语附录里写明为什么。
- 探针屏的横幅优先级：`WAL_UNAVAILABLE`(4) > `SECURE_UNREADABLE`(3) > `WAL_TRUNCATED`(2) > `TURN_INTERRUPTED`(1) 是本轮定的；产品面是否需要同时显示多条？
- 产品文案落在 `:lib`（只读车道），本轮只在探针屏 footer 加了诚实声明，正式文案需要 UI 车道同步。
