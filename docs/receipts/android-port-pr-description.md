# Android 完整适配：12 个模块、1475 个 JVM 测试、真模型回合跑通、27 个设备级缺陷闭合

以 `spec/v1` 为唯一裁判、iOS 为基线，把 PDSH 移植到 Android。本 PR 覆盖 P0–P6，
**真机测试按约定留到合并后**。

本地验证：**1475 个 JVM 测试 0 失败**（`test-count.sh` 无 `WARN`）、**structure_check 11/11**、
**spec golden 73 文件 0 error**、**spec 单测 185 通过**、`cargo test --workspace` 全绿。

---

## 做了什么

**12 个 Gradle 模块**：`:platform` `:platform-android` `:core` `:net` `:controller` `:engine`
`:dsh` `:lib` `:testkit` `:domain` `:shell` `:app`。

**4 棵契约树**（`spec/v1`、`spec/host/v1`、`spec/platform`、`spec/ui/v1`）+ 跨树不变量检查。

**Rust 加速器**：WAL 内核、wire 编解码、`rg`/`jaq`/`jq` 进程内加速器，全部经 JNI 暴露。

**Worker**：TS 运行时打成一个镜像，WebView 里跑，与宿主走有序通道（`spec/v1/channel.md`）。

**能力面**：92 个声明命令，实测 **91 可用**、1 个诚实标注不可用（`curl`，phone profile 不下发 loopback token）。

---

## 验证（每条带证据等级）

| 项 | 结果 | 等级 |
|---|---|---|
| JVM 测试 | **1475 / 0 failing** | `jvm` |
| 结构检查 | **11 / 11** | `jvm` |
| spec golden | 73 文件 / 0 error | `jvm` |
| spec 单测 | 185 通过 | `jvm` |
| `cargo test --workspace` | 全绿 | `jvm` |
| 真模型回合 | `APP_TURN_OK reason=completed` | `emulator` |
| 92 命令对账 | 91 ok / 1 fail（`curl`，已标注） | `emulator` |
| 冷启动 median | 4941 ms（API 35 模拟器，**不是真机**） | `emulator` |
| 首回合 TTFT median | 1779 ms | `emulator` |
| 单回合 RSS 峰 | ~289 MiB | `emulator` |
| 进程被杀矩阵 | 5 种杀法 × 2 时机：**0 torn / 0 丢失** | `emulator` |
| 真机任何数字 | **无** | `not-verified` |
| 掉电（`level-2`） | **已降级，不承诺** | `not-verified` |

---

## 这一轮修掉的 27 个设备级缺陷

**全部由设备实测发现**。1475 个 JVM 测试一个都没抓到——它们只存在于
「真实进程 + 真实 WebView + 真实文件系统 + 真实加速器」的组合里。

### 🔴 数据泄漏 / 可用性（5 个）

| # | 缺陷 | 证据 |
|---|---|---|
| 1 | **`rg` / `jaq` 加速器能读 DSH 内部状态全文**（会话日志、tool journal），违反 `channel.md:262` | 宿主层 + Worker 层双修；设备实测三个根全 `EACCES`，`capabilities.json` 仍可读（正控） |
| 2 | **WAL 三种形态都把工作区判死**：0 字节段、大记录 torn tail 被预算误判、「未列出的 epoch」被当损坏 | 用**真实砖化快照**恢复出 `next_mseq=583/582`；三条形态各自独立反向验证 |
| 3 | **切后台 10 分钟后 App 永久不可用**：`DrainCompleted` 在任何 main 源集都没有生产者，`Draining` 结构上是终态 | 设备 10 分钟实测：52 ms drain → Parked → 回前台 Running → `APP_TURN_OK` |
| 4 | **写满 128 MiB 后每次启动崩溃**：`JsonParser` 峰值达 9× 记录大小（1.2 GiB），2 GB 设备必 OOM | 流式恢复；峰值 165 MiB → 61–83 MiB；`-Xmx128m` 子进程（堆小于文件）恢复通过 |
| 5 | **通道断开后永久不自愈**：worker 自己关通道（`BAD_MSEQ`），客户端置 `fatalError` 再不重连 | `ChannelReopenLane` 用既有状态机边；设备 1.1 s 恢复 → `APP_TURN_OK` |

### 契约一致性（12 个）

`python3`/`jq` 100% 失败；`phone` 工具面声明 19 个只有 1 个能用；同一个拒绝策略**四种渲染**
（`ls`/`cp`/`cat`/`rg`）；`jq` 截断静默服务残缺视图；WASI guest 把「被拒」报成「不存在」；
内部根名字仍可被 `glob` 展开；写侧能写 `/`、`/dsh/config`、`/dsh/bin`；超限不给 `EFBIG`；
budgets 档位从未按内存选择；误配置产生真实外网流量。

### 其他（10 个）

无工具调用的完成回合被判失败、WebView 门槛写成 Chromium 99（实际 124）、16KB 页对齐缺失、
ingress 幂等零实现、`admission` 关闭时烧掉 21,574 个 mseq、
`ProbeLaunchConfig` 把自己的 KDoc 反着实现，等等。

**每个修复都带反向验证**：去掉修复，对应测试必须红，且**错误文本与设备日志同形**。

---

## 五个根源（不是 27 个孤立失误）

这是本轮最重要的发现：

| 根源 | 实例 | 表现 |
|---|---|---|
| **一个策略多套渲染/能力** | 6 | 同一个拒绝，`ls` 给 EACCES、`cat` 给 ENOENT、`rg` 直接放行；`bash` 能写 `/dsh/home` 而 `write`/`edit` 不能 |
| **状态机有入口无出口** | 6 | `Draining`/`Backoff`/通道断开/`PlannedRestart`/handoff/429 —— 出口都停在纸面上 |
| **修了源码没进产物** | 6 | 三份产物 × 一个 CJS 降级步骤；任何一环漏掉都白干 |
| **把未知折成已知** | 6 | 「我没看到 X」→「X 不存在」：EACCES→ENOENT、torn tail→CORRUPT、没有模型路由→凭据无效 |
| **测量工具与实现不同源** | 4 | 探测问原生而 worker 跑垫片；探针装 1 个属性而 worker 装 14 个；`test-count.sh` 读部分结果报「0 failing」 |

所以每个修复都要求**机器检查**而不是「这次改对」：

- 产物陈旧 → `bundle-freshness` 门禁（6 产物 × 源目录 mtime）
- 渲染分叉 → 单一出口的统一渲染层 + 「新命令也不会漏」的测试
- 探测漂移 → 跑**真实的** installer 抽属性名，差集非空即红并点名
- 测试数假绿 → 结果文件数 < 测试源文件数就 `WARN`

---

## ⚠️ UI 是本 PR 的明确缺口

**这不是「还差一点」，是「没做」。** 单独列出来，避免被当作已完成。

| 层 | 状态 |
|---|---|
| **能力面**（通道、执行面、持久化、生命周期、安全边界） | 已实现并有设备证据 |
| **UI 结构对齐** | **缺口** |
| **布局/像素级对齐** | **缺口** |
| **iOS 基线追平** | **缺口（且基线还在增长）** |

### 为什么是缺口

1. **iOS 基线在本轮期间仍在追加页面**：11:43–11:50 之间新增了
   `NativeDeviceSessionPage`（18.9 KB）、`SessionArtifactsPage`（13.4 KB）、
   `NativeDeviceConnectionPage`（6.7 KB）、`ChatPreferencesPage`、`SessionArtifactPreviewPage`。

   **这三页不是 UI 重排，是设备连接器能力**（`DeviceTransportAdapter` / `DeviceControlPort`）——
   Android 侧一行都没有。

2. `spec/ui/v1` 的页面清单只覆盖到基线 11:43 之前的状态，
   `phone-p0-conformance` 因此红：`README page inventory misses: ChatPreferencesPage,
   NativeDeviceConnectionPage, NativeDeviceSessionPage, SessionArtifactPreviewPage,
   SessionArtifactsPage`。

3. `:lib` 里的 11 个路由页**结构已抽、未接路由**——它们不渲染，也没有会话数据。

### 所以 UI 相关门禁的红**不作为本 PR 的进度指标**

`phone-p0-conformance` 的红是**基线在动**，不是 Android 退步。

### 基线冻结后要做的事

1. 重新跑 `extract_ios_pages.py`，`--write-baseline` 刷新页面清单
2. 补 `spec/ui/v1/README.md` 的 5 个新页面（当前 280 行，需要抬 cap）
3. **新实现**设备连接 / 设备会话 / 会话产物三块能力——这是功能，不是界面调整
4. 把 11 个未接路由的页面接上数据
5. 逐像素对齐（`docs/receipts/ios-baseline-screens/` 有 27 张基线截图可用）

---

## 没有验证的（重要）

| 项 | 状态 |
|---|---|
| **真机任何数字** | 无。全部设备证据来自 API 35 模拟器 |
| **掉电（`level-2`）** | **已降级**。模拟器是宿主上的 QCOW2，无 UFS write cache/FTL，`fsync` 经 QEMU 中转——做不了真掉电。承诺收窄为「进程被杀不丢 + 尾部可检出」。升级条件见 `docs/design/android-durability-decision-2026-11-01.md` |
| **HarmonyOS** | 无设备，未测 |
| **灭屏 / Doze 10 分钟** | 只做 HOME 后台；模拟器 Doze 与真机不等价 |
| **真实 LMK** | `send-trim-memory` 实测 pid 不变；用后台 `am kill` 作同类证据并标注 |
| **API 26–32 / 真机 WebView <124** | 未测。Chromium 109 已在模拟器上跑通（靠前置垫片） |
| **P95 延迟** | 10 个样本给不出；且宿主同时跑多个模拟器 |
| **StrongBox / TEE 下的锁屏矩阵** | 模拟器 Keystore 是 `SOFTWARE` |
| **UI 结构对齐** | **暂停**。iOS 基线仍在追加页面（11:43–11:50 又加了 5 个），冻结后重做 |

**测试数说明**：`test-count.sh` 的 `WARN` 机制是本轮新增的——一次过滤运行
（`gradlew --tests X`）会留下部分结果，之后全量运行被判 UP-TO-DATE，于是**显示「0 failing」而只跑了 1.7%**。
报出的 1475 是**全量重跑**后的数字。

---

## 六项「已实现、待接线」

**不是 bug，是没接。** 列出来是为了不让人以为已完成：

1. 11 个页面结构已抽、未接路由
2. `ChatRow.Context` 投影已算、未显示
3. 入站附件未接
4. sessions facts adapter 未接
5. `IngressQueue`（持久 ingress + 重启去重）、`BackgroundExecutionFacts` 已实现、**无产品调用点**
6. **`PDSH_MODEL_KEY_STATE`**：已发布，**全仓库零消费者**

---

## 我们改不了的（契约 / 上游问题）

| # | 问题 | 归属 |
|---|---|---|
| 1 | `channel.md:264` 写「tier default (64/48/32/16 MiB)」，`budgets.md:104` 是「256/128/48/32/16」——**四条对五行，且错的是 wire 契约那份** | spec owner |
| 2 | `wal.md §3` 的 `len` 是 `u32`，**全文没有单条记录上限**；15 MiB 靠 `channel.md §3.1` 继承 | spec owner |
| 3 | `channel.md` 只在 D4 提了「upstream sandbox grants /tmp」，**从未声明 `write`/`edit` 的写面比 VFS 根表更窄**（差集 `/dsh/home`、`/dev/null`） | spec owner |
| 4 | `channel.md:262` 只列 `bash, python3, git` 为例，未列 `jq`/`jaq`（它们也是执行面且已合规） | spec owner |
| 5 | **DSH 自相矛盾**：`user-approval` 的 `NEVER_SENTENCE` 说「不要请求提权」，同一请求的工具结果说「escalation available, retry with `sandbox_permissions`」。且 `tool-bash` 的判据只看「是否挂了强制沙箱」，**从不查 approval 策略** | 上游 DSH |
| 6 | `tool-fs/src/sandbox.ts` 的 `mapError` 对 `FS_SANDBOX_DENIED` **整段替换** provider 的原因文本 → `write`/`edit` 被拒时模型**零诊断** | 上游 DSH |
| 7 | `llm-deepseek` 在 `DEEPSEEK_BASE_URL` 缺失时**回落到官方 base**，用占位符发真实请求 | 上游 DSH |

第 5–7 条我们做了降害（AGENTS.md 反向指令、追加第二个 text block 诊断、
宿主显式发布 `PDSH_MODEL_ROUTE=none` 让 worker 本地拒发），但**根治需要上游改**。

---

## 参考实现的 bug（本轮顺带修的）

| # | 问题 |
|---|---|
| 1 | 本回执正文多处数字与实测不符（测试数、模块数、`level-2` 状态），已按实测更正 |
| 2 | 「三份产物」表把 `shell-ext` 错记在 `worker-entry.js`，实际在 `image.tar.gz` |
| 3 | 「`bundled worker` 对 `VFS_RESYNC` 只 decode 后 return」——错，`notify(frame)` 会触发整文件重发 |
| 4 | 契约条款位置记错（`wal.md §3.4` 实际是 `channel.md §3.4`） |

---

## 三个值得单独看的设计判断

**1. 「不可见」不等于「不存在」**

`ls /dsh/home` 不再列出三个内部根的名字（连 `glob` 展开也不行），但显式访问
`ls /dsh/home/sessions` **仍返回 EACCES**——不是 ENOENT。

契约补句建议：`invisibility is not absence`。

**2. 「不知道」必须能被表达**

`env` 里没有 `DEEPSEEK_BASE_URL` 是**二义**的（挂 edge 时 engine 也先省掉再注入），
所以宿主显式发布 `PDSH_MODEL_ROUTE=none` + `PDSH_MODEL_ROUTE_MISSING=base-url`，
worker 本地拒发并说明「缺的是端点，不是凭据」。

**不从「缺失」推断「事实」**，是今晚 6 个缺陷的共同解药。

**3. 证据等级写在代码里**

```kotlin
// ---- evidence level: JVM only, no device capture ----
// There is no device-level evidence for this branch. … Do not read the device run
// (2 GiB AVD: EFBIG … limited to 16777216 bytes) as proof that this branch fired.
```

明确写出**这条证据不能用来证明什么**，比「本分支有测试覆盖」有用。

---

## 已知的门禁红（不是回归）

| 门禁 | 原因 |
|---|---|
| `phone-p0-conformance` | iOS 基线 11:43–11:50 新增 5 个页面，清单未覆盖——**基线在动，冻结后处理** |
| `phone-hygiene` | `docs/receipts/ios-session-audit/**` 含绝对路径与 `hostname: Chrome.app` |
| `phone-license` | `spec/ui/v1/tools/*.py` 缺 SPDX |
| `phone-bundle-fresh` | 本轮多人并行改 `plugins`，产物需最终原子重建 |

**`Bundle/worker/**` 是 gitignore 的 65 MB 构建产物**，所以干净 CI 无法 `assembleRelease`
（退出码 2）。这一点**没有伪造**，如实记录。

---

## 完整证据

`docs/receipts/android-port-2026-10-31.md`（65 节，逐条设备输出与反向验证）。
