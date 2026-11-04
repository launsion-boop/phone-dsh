<!-- SPDX-License-Identifier: MIT -->
# 评估：Android 的 level-2 掉电承诺还能不能拿回来

日期：2026-11-01 · 车道：L42（P3/P3.5 复核） · 状态：**降级决定不变，但论证需要换地基**
配套：[android-durability-decision-2026-11-01.md](android-durability-decision-2026-11-01.md)（决定记录）、
[android-p6-kill-matrix-2026-11-01.md](../receipts/android-p6-kill-matrix-2026-11-01.md)（killed-by-process 证据）

本文回答四件事：**level-2 需要什么**、**哪一半没有台架也能验证**、**现在已经测到了什么**、
**拿到 level-2 的最短路径**。不改决定，不改代码，不改 `spec/**`。

---

## 0. 结论先说

1. 现有决策记录论证的是「**本轮没有台架，所以做不了设备类测量**」（测量缺口），
   它并**没有**论证「level-2 做不到」（能力缺口）。决策记录 §2 里「fdatasync 只保证数据到达存储栈」
   这句也偏保守——见本文 §2.3。
2. level-2 的验收判据是一个**四层合取**（§1）：原语、排序、设备兑现、恢复不砖化。
   其中三层**不需要台架**就能验；而第 4 层（恢复）**今天就是红的**：掉电形状的 0 字节段
   可稳定复现（§4.2 K3），一击就把工作区打成 `WAL_CORRUPT` → `wal/1 off`。
3. 所以卡点不是「没台架」，是「机制还没修到配得上一次台架」。**先修机制 → 再跑模拟器矩阵
   → 最后上台架**才是最短路径（§6）。在 ①+② 绿之前，`LEVEL_2_POWER_LOSS_MEASURED`
   不可返回——现有代码行为正确，不动。
4. 没有台架**能**验证的那一半，判决性 case 在 §4.2，复跑命令在 §7。全部在本机 30 分钟内可重跑。

---

## 1. level-2 到底是什么：四层合取

`spec/v1/wal.md` §5.2 的 level-2 是「纪元关闭记录 + 该纪元每个段 `F_FULLFSYNC` + 目录 fsync 之后
才发的 ack-2」，语义是「**掉电最多丢最后一个纪元**」。要在 Android 上成立，需要四层同时为真：

| 层 | 要验证什么 | 失败长什么样 | 需要什么 | 今天能不能验 |
| --- | --- | --- | --- | --- |
| **L0 原语** | 有 `fsync(2)` 语义的原语，且能 fsync **目录** | 编译期就缺，或只 `fdatasync` 丢了 dirent | 无（系统 API） | **能**：`AndroidDurabilityDeviceTest`（已在仓库） |
| **L1 排序** | `写 temp → fsync(file) → rename → fsync(dir)` 之后，页缓存丢了也不出现 0 字节/旧内容/半截帧 | 文件在、内容 0 字节；rename 没发布；帧半截 | 一次「页缓存丢失」的切割 | **能**：模拟器 `adb emu kill`（§4.2 已做） |
| **L2 设备** | 设备 write cache / FTL **兑现** flush：`fsync` 返回 0 之后数据真的在介质上 | fsync 成功但重启后是旧数据/丢数据 | 真机 + 可控断电（继电器/电源开关） | **不能**：需要台架 |
| **L3 恢复** | 「合法的掉电残缺」被当成可恢复前缀，而不是 `WAL_CORRUPT` | 工作区不可用（`wal/1 off`），没有产品内修复路径 | 无（纯逻辑 + 注入） | **能**：注入 0 字节段即可（已做，见 BUG-1） |

**关键点**：L2 的不确定性只影响「这句话能不能对外说」；L1/L3 的失败直接让决策记录 §7 的
**验收判据本身不成立**（「不出现 `WAL_CORRUPT`」）。所以「等台架」不是最短路径——
即使明天台架到位、20 次切割全绿，只要 L3 还是红的，结果也只能写成「机制未达标」。

---

## 2. 原语盘点：Android 有没有「真正的 fsync」

### 2.1 有的是什么

| API | 真实语义 | 本仓库用在哪 |
| --- | --- | --- |
| `FileChannel.force(true)` | `fsync(2)`（含 metadata） | `ChannelFileSync`（`AndroidDurability.kt:56`），段文件/物化文件 |
| `FileChannel.force(false)` | `fdatasync(2)`（可省 metadata） | 未用（D18 需要 metadata） |
| `FileDescriptor.sync()` | `fsync(2)` | 未用，与上等价 |
| `android.system.Os.fsync(fd)` | `fsync(2)`（raw fd） | `OsDirectorySync`（`AndroidDurability.kt:71`）——**Java 没有目录 fsync，只能走这条** |
| `android.system.Os.fdatasync(fd)` | `fdatasync(2)` | 未用 |

三条路都到同一个 `fsync(2)`，**没有「落不到盘」的原语缺口**。`OsDirectorySync` 的
`Os.open(dir, O_RDONLY)` + `Os.fsync` 也是 Android 上唯一能刷目录的办法，代码注释说的没错。

### 2.2 没有的是什么

没有 `F_FULLFSYNC`。但**这不等于「Android 的 fsync 比 iOS 弱一档」**——见下。

### 2.3 更正一处措辞：Linux 的 fsync 自己就会发 flush

决策记录 §2 和 whitelist 的 rationale 都写着「fdatasync 只保证数据到达**存储栈**」。
更准确的说法是：

> Linux 上 `fsync`/`fdatasync` 在设备声明了 volatile write cache 时，会走块层的 flush 机制
> （`blkdev_issue_flush` → `REQ_OP_FLUSH`），即**要求设备把缓存刷到介质**；ext4 在
> `barrier` 开启时正是这么做的（LKML：ext4 call blkdev_issue_flush on fsync，2008；`block/blk-flush.c`）。
> 所以 Android 的 `fsync` 在语义上更接近 `F_FULLFSYNC`，而不是 macOS 那个「只到盘缓存」的 `fsync`。

剩下的不确定性只有三个，且**都不是「原语缺失」**：

1. 挂载把 barrier 关了（`nobarrier`/`barrier=0`）；
2. 设备固件**收下 flush 但不刷**（廉价 eMMC/UFS 的已知失效模式）；
3. 文件系统自己有 bug——f2fs 到 2026-03 还有「fsync 不写 node folio 导致丢数据」的补丁
   （linux-f2fs-devel 邮件列表，2026-03 那条 "fsync 不写 node folio" 补丁）。

这就是为什么 level-2 在 Android 上**是「按设备类实测」而不是「机制保证」**——这个结论
成立，但理由要改成「设备是否兑现 flush 无法从 API 侧证明」，而不是「我们只有半个原语」。

---

## 3. 文件系统事实：`data=ordered` 还是 `writeback`

实测对象：自建 AVD `l42probe`（`system-images;android-35;google_apis;arm64-v8a`，Android 15，userdebug）。

```bash
adb -s emulator-5684 root
adb -s emulator-5684 shell 'cat /proc/fs/ext4/dm-44/options | grep -E "data=|auto_da_alloc|delalloc|barrier|commit="'
# delalloc / barrier / auto_da_alloc / commit=5 / data=ordered
adb -s emulator-5684 shell 'cat /sys/block/dm-44/queue/write_cache'
# write back
```

| 事实 | 对 D18 的含义 |
| --- | --- |
| `data=ordered`（不是 writeback） | 数据块先于引用它的 metadata 提交 → 崩溃后不会暴露未初始化块；但**不保证**「写完之后过一段时间一定落盘」，也不保证 inode size 的更新已提交 |
| `delalloc` + `auto_da_alloc`（**没**被 `noauto_da_alloc` 关掉） | rename-over-existing 时 ext4 会强制 flush/commit。实测 §4.2 的 L：**完全没 fsync 的 rename 也活下来了**——但这是 mount 相关的启发式，OEM 可以关，f2fs 没有等价物，**不能依赖** |
| `barrier`（开） | fsync 会发 flush；若被关，D18 的 fsync 只到块层 |
| `commit=5` | 日志每 5 s 提交一次 → 一个「刚创建、还没 fsync」的段，其 dirent/size 最多 5 s 后就可能被提交成「size=0」 |
| f2fs | 未实测。f2fs 的 fsync 依赖 checkpoint/roll-forward，且历史上有 fsync 丢数据的修复（见 §2.3 第 3 条）→ **必须单独设备类实测** |

**「写完文件再 fsync 目录」够不够？** 在 ext4 上，`fsync(file)` 已经通过日志提交把同一事务里的
新目录/dirent 一起发布了（实测 G3、Q：两级新目录 + 只 fsync 文件，崩溃后目录和文件都在）；
`fsync(dir)` 是给「dirent 落在另一个事务」和 f2fs 场景的保险。它不是装饰，但也不是唯一依赖 ——
**而 `fsync(dir)` 单独用绝不能替代 `fsync(file)`**（实测 J、J3：只刷目录，1 MiB 数据全丢、size=0）。

---

## 4. 没有台架也能做的那一半：模拟器 crash 矩阵

### 4.1 方法与边界

```bash
emulator -avd l42probe -port 5684 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect &
adb -s emulator-5684 wait-for-device && adb -s emulator-5684 root
# 写入（脚本见 §7），然后同一行里立刻切：
adb -s emulator-5684 shell sh /data/local/tmp/round2.sh r2
adb -s emulator-5684 emu kill          # VM 进程直接死，guest 页缓存没机会回写
# 重启同一 AVD，ext4 journal replay，然后验：
adb -s emulator-5684 shell sh /data/local/tmp/verify2.sh r2
```

- **为什么这不是「假装掉电」**：它测的是「guest 页缓存丢失之后，磁盘上剩下什么」，
  以及 ext4 journal replay 之后应用看到的字节。这正是真掉电要走的那段代码。
- **为什么它仍然不是掉电测试**：数据分区是宿主上的 QCOW2（`file userdata-qemu.img` →
  `QEMU QCOW2 Image (v3)`），没有 UFS/eMMC、没有 FTL、没有设备 write cache；
  切割点是「整个 VM 死掉」而**不是**「在 epoch close 的 fsync 之间随机断」。
- **实测：Android 15 上 `sysrq` 这条常用替代路不通**。`/proc/sysrq-trigger` 连 root 都写不了：

  ```bash
  adb -s emulator-5684 shell 'echo 1 > /proc/sys/kernel/sysrq'   # Permission denied
  adb -s emulator-5684 shell 'setenforce 0'                       # Permission denied
  adb -s emulator-5684 shell 'reboot -f'                          # usage: reboot [-p] ...（toybox 不支持）
  ```
  所以别把「Linux 标准 sysrq-b 模拟掉电」当成 Android 的可用手段：**可用的只有 `adb emu kill`**，
  或者真机上用继电器。

### 4.2 判决性 case 与实测结果（3 轮，同一 AVD，`adb emu kill`）

`fsync` 用 toybox：`fsync FILE`（= `fsync(2)`），`fsync -d FILE`（= `fdatasync(2)`），
目录也可以直接 `fsync DIR`（`fsync(2)` 一个 O_RDONLY 的目录 fd）。

r1 是**对照组**（写入后 ≥30 s、约 1 min 才切，已超过 30 s 脏页过期窗口，让脏页有机会回写；未精确计时），r2/r3 在写入后 **0.24–0.3 s** 切。
表里的 `(r1)` / `(r2)` / `(r3)` 是实际跑的轮次。

| case | 切割前做了什么 | 掉电后应该 | **实测** |
| --- | --- | --- | --- |
| A / A2（r1，**≥30 s 后才切**） | 写 1 MiB，**不 fsync** | 允许丢 | **size=0** → 时间不会替你做 fsync |
| N / N3（r2/r3，紧切） | 写 1 MiB，**不 fsync** | 允许丢（这是尾巴） | **size=0** |
| J / J3 | 写 1 MiB + **只 fsync 目录** | 不该活 | **size=0** → 目录 fsync 不能替代文件 fsync |
| G / H / G3 | 写 1 MiB + **fsync 文件**（G3 还放在两级新建目录里、目录从不 fsync） | 必须活 | **字节一致（sha256 相同）** |
| Q | 两级新目录 + 文件 + 只 fsync 文件 | 必须活 | **目录与文件都在，sha 相同** → `fsync(file)` 顺带发布了同一事务的 dirent |
| D2 / D3 / U3 | 写 4096 B 段头形状，**不 fsync** | 允许丢 | **size=0** → 文件在、内容没了 |
| **K3** | **先 `: > seg; fsync DIR`（把空 inode 发布出去），再写 4096 B 负载，不 fsync** | 允许丢 | **size=0** ← **这就是 BUG-1 的 0 字节段** |
| D1（r1） | 建空文件 → 等 7 s（日志已提交空 inode）→ 写负载 → **同轮别的文件 fsync 之后**才切 | 边界 | **size=4096（活了）** ← 被别人的 fsync 顺带提交 |
| L | 写 temp + rename over existing，**全程不 fsync** | 允许丢 | **新内容完整**（ext4 `auto_da_alloc` 的强制提交）→ 不能依赖 |
| M / P | 写 temp + fsync(temp) + rename（P 还 fsync 目录） | 必须活 | **新内容完整** |

### 4.3 六条结论

1. **`fsync(file)` 是分水岭**：刷了的一个不丢（G/H/G3/Q/M/P），没刷的全变 size=0（A/A2/N/N3/J/J3/U3/D2/D3/K3）。
   说明「页缓存丢失」这个切割是**真实发生**的，不是空转。
2. **`fsync(dir)` 不能替代 `fsync(file)`**（J/J3）。D18 的顺序是「先文件、后目录」，这不是风格问题。
3. **0 字节 artifact 可以按需复现**（K3）：inode 以 size=0 被日志提交、payload 后写且没 fsync，
   崩溃后就是「文件在、0 字节」。这**与设备 write cache 无关**，是写—提交顺序问题——
   所以**台架修不了它**，模拟器今天就修得掉。注意：这是**构造**出的窗口，不是从应用侧
   抓到的真实时序；结论只到「这一类排序会产生这个形状」，不到「线上就是这么发生的」。
4. **`fsync(file)` 会顺带发布同一事务里的新 dirent**（G3/Q）：因此修 `createSegment`
   只需要在写完 header 后 fsync 一次文件，不必额外加目录 fsync。
5. **单次「活下来了」没有意义**：同一轮里别的文件的 fsync 会把整条日志提交，
   把之前的脏数据一起带下去（D1 就是这样活下来的）。这正是决策记录 §7.2
   「每类 ≥20 次随机点断电」的由来——**跨 case 的结果不能当独立证据**。
6. **模拟器只可证伪、不可证实**：r1 里 ≥30 s 没 fsync 的数据仍然全丢（A/A2），
   而真机上 30 s 脏页回写通常已经把它写下去了。所以「模拟器上活下来」推不出「真机上活下来」；
   反过来「模拟器上丢了」也不必然是真机丢。这一层只能验**排序是否自洽**，不能给**设备类**下结论。

### 4.4 如果要把这一半当 gate，判据是

每次冷启动后：① 恢复出合法前缀；② 丢失 ≤ 最后一个已关闭纪元；③ **不出现 `WAL_CORRUPT`**
（含 0 字节段形态）；④ journal 能指出缺失的步。**允许**丢未 ack 的尾巴，**不允许**工作区不可用。
连续 ≥20 次随机点切割全绿才算这一半过。

---

## 5. 需要台架的那一半（设备类）

| 项 | 要求 |
| --- | --- |
| 硬件 | 可编程继电器/USB 电源开关（计划 §14.3-4 已列为 P0 采购项）；≥1 台 f2fs、≥1 台 ext4；能改 UFS cache 模式更好 |
| 矩阵 | `{f2fs, ext4} × {cache on, off} × ≥20 次`，切割点用 app 侧打点（epoch close 的 5 步之间）随机延迟，而不是「随便杀」 |
| 每次记录 | 机型/内核/FS/挂载选项/`queue/write_cache`、切割时刻与相对 epoch close 的位置、串口或 kmsg、恢复日志、`next_mseq`、丢失记录数、是否 `WAL_CORRUPT`、journal 缺失步 |
| 通过 | §4.4 的 ①–④ 全部成立，且 **fsync 返回成功之后的数据一次都没丢过** |
| 反面判据 | 出现「fsync 返回 0 但数据丢」→ 该设备类**永久** `UNVERIFIED`，把实测窗口写进 `spec/platform` 附录（需 spec owner） |
| 产物 | 一条设备类结论 = 一份可复现记录；没有记录的「我们测过了」不算 |

---

## 6. 从今天到 level-2 的最短路径（5 步，都在本仓库可落）

| # | 动作 | 谁做 | gate（可验证） | 需要台架？ |
| --- | --- | --- | --- | --- |
| 1 | `createSegment` 写完 40 B header 后 **fsync 文件**（`WorkspaceLog.kt:1274`；现在只在纪元关闭时刷，窗口 30–60 s）。成本：**每纪元 1 次 fsync** | `:core` | §4.2 K3 变绿：掉电后不再出现 0 字节段 | **否** |
| 2 | 恢复层容忍「未列入 manifest 且长度 < header」的段（BUG-1；`spec/v1/wal.md` §7.2/§10 决策） | spec owner + `:core` | 注入 0 字节段后 `wal/1` 仍 `on`，前缀完整 | **否** |
| 3 | 把 §4.2 的矩阵脚本化，≥20 次随机点切割 | `:app`/`testkit` | §4.4 ①–④ 全绿 | **否** |
| 4 | 真机 × 20 次 × 单设备类 | 硬件/QA | §5 判据 | **是** |
| 5 | 扩设备类 + 文案；只有这时 `level()` 才可返回 `MEASURED`，且只对已测类别 | `:platform-android` + 产品 | whitelist `platform.fsync-epoch-close` 的 `evidence_level` 要从 `device-gate` 换成一份带设备类的实测记录（字段与判据见 §5） | **是** |

**为什么这个顺序不能反**：第 1、2 步的失败形态（0 字节段 → 工作区不可用）是**设备无关**的，
台架只会更贵地复现同一件事。第 4 步之前必须把 1–3 做完，否则台架记录里会混进「恢复层
自己砖化」的噪声，判不出是设备不兑现 flush 还是我们没写对。

---

## 7. 复跑命令（本机可重跑；本轮实测就是这个）

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

# 0) 自建 AVD（端口 5684，不碰别人的 5556/5558/5670–5682）
avdmanager create avd -n l42probe -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_6 --force
emulator -avd l42probe -port 5684 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect &
adb -s emulator-5684 wait-for-device && adb -s emulator-5684 root

# 1) 推脚本（注意：脚本自己也要 fsync，否则会被下一次切割吃掉——本轮真的踩到过）
adb -s emulator-5684 push round2.sh  /data/local/tmp/round2.sh
adb -s emulator-5684 push verify2.sh /data/local/tmp/verify2.sh
adb -s emulator-5684 shell 'fsync /data/local/tmp/round2.sh /data/local/tmp/verify2.sh'

# 2) 写入 + **同一行**切割（间隔约 0.2–0.3 s）
adb -s emulator-5684 shell sh /data/local/tmp/round2.sh r2
adb -s emulator-5684 emu kill

# 3) 重启（同一 AVD，userdata 保留）→ ext4 journal replay → 验
emulator -avd l42probe -port 5684 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect &
adb -s emulator-5684 wait-for-device
adb -s emulator-5684 shell sh /data/local/tmp/verify2.sh r2

# 4) 清理
adb -s emulator-5684 emu kill; avdmanager delete avd -n l42probe
```

`round2.sh`（判决性 variant，注意顺序：不 fsync 的放最后，避免被同轮其它 fsync 顺手提交）：

```sh
#!/system/bin/sh
R="${1:-r2}"; BASE="/data/local/tmp/l42/$R"; rm -rf "$BASE"; mkdir -p "$BASE"
mk1() { dd if=/dev/urandom of="$1" bs=4096 count=256 2>/dev/null; }
mkdir -p "$BASE/N"; mk1 "$BASE/N/data.bin"                                   # 不 fsync
mkdir -p "$BASE/G"; mk1 "$BASE/G/data.bin"; fsync "$BASE/G/data.bin"         # 只刷文件
mkdir -p "$BASE/H"; mk1 "$BASE/H/data.bin"; fsync "$BASE/H/data.bin"; fsync "$BASE/H"
mkdir -p "$BASE/J"; mk1 "$BASE/J/data.bin"; fsync "$BASE/J"                  # 只刷目录
mkdir -p "$BASE/K"; : > "$BASE/K/seg.xlwal"; fsync "$BASE/K"                  # 先发布空 inode
dd if=/dev/zero of="$BASE/K/seg.xlwal" bs=4096 count=1 2>/dev/null           # 再写负载，不 fsync
mkdir -p "$BASE/G3/inner"; mk1 "$BASE/G3/inner/data.bin"; fsync "$BASE/G3/inner/data.bin"
for v in N G H J; do echo -n "$v "; sha256sum "$BASE/$v/data.bin"; done
echo -n "G3 "; sha256sum "$BASE/G3/inner/data.bin"
echo "=== written, kill now ==="
```

`verify2.sh`：

```sh
#!/system/bin/sh
BASE="/data/local/tmp/l42/$1"
ls -l "$BASE"
for d in "$BASE"/*/; do for f in "$d"*; do
  [ -e "$f" ] || { echo "$(basename "$d")/$(basename "$f") MISSING"; continue; }
  echo "$(basename "$d")/$(basename "$f") size=$(stat -c '%s' "$f") sha=$(sha256sum "$f" | cut -d' ' -f1)"
done; done
```

---

## 8. 我没验的 / 本结论可能错在哪

| # | 没验的 | 影响 |
| --- | --- | --- |
| 1 | QEMU 的 cache 模式不在 argv 里（`-avd` 之外的盘参数是 emulator 内部拼的），无法证明「模拟器的丢失窗口 ≥ 真机」 | §4.2 的「不 fsync 必丢」可能被 QCOW2 元数据缓存放大；真机上「过 30 s 的脏页」未必丢。所以模拟器**只能证伪、不能证实**，§4.4 的 gate 也只写成必要条件 |
| 2 | 只测了 ext4，没测 f2fs | f2fs 的 dirent/fsync 事务边界不同，§3 关于「fsync 顺带发布 dirent」的结论不能外推 |
| 3 | 只测了 shell 级 write/fsync，没在**真实 D18 五步**的每一步之间切 | 真实时序里 materialized fsync → close record → 段 fsync → 目录 fsync → manifest 的中间态没有逐点打断；§6 第 3 步的 gate 必须在应用路径上重跑 |
| 4 | 3 轮不是 20 轮，且同轮 case 之间会互相提交日志（§4.3-5） | 单 case 的一次结果不能当独立证据；只能当「方向性 + 可复现」 |
| 5 | 没验证 `FileChannel.force(true)` 在具体 OEM 上的行为 | 代码层是 `fsync(2)`，但 OEM 内核补丁无法审计；属 §5 台架范围 |
| 6 | 没跑 `AndroidDurabilityDeviceTest` 的设备级复跑（本轮只读代码） | L0 层的结论来自代码阅读 + 既有测试存在，不是本轮实测 |

**如果我的结论错了，最可能错在**：把「模拟器能造出 0 字节段」当成了「真机也会」，
以及把「构造出的窗口」当成了「线上真实的窗口」。
K3 的排序在 ext4 `data=ordered` 下是**文件系统层**的行为，理论上与设备无关；但如果真机
（尤其 f2fs）在 `fsync(dir)` 之后、payload 写入之前的时间窗里把 inode 的 size 更新也刷下去了，
那 0 字节段的概率会低很多——不过**这不改变结论**：修 §6 第 1、2 步的成本远低于一次台架，
而且是 level-2 的必要条件，先修不亏。
