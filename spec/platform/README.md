# spec/platform — 平台差异白名单

Status: P0 骨架（方案 §5.2、§10），契约 `platform-whitelist 1`，MIT。

这个目录只做一件事：把「iOS 与 Android 之间哪些差异是合法的」变成机器可读的事实。
方案 §5.2 的原话是**白名单机器可读，否则会长成第二份散文 spec**——所以本树的验收标准不是
「写清楚了」，而是「checker 能机械判定每一条差异都合法、有出处、有证据等级」。

三条可机械判定的义务，其余都是细节：

1. **合法**：`divergence_class` 只能是三类之一，且 `rationale` 说明语义等价与不许放宽的部分。
2. **有出处**：`spec_ref` 指向仓库内真实存在的文件，且该文件里能搜到所引节号的标题。
3. **有证据等级**：`evidence_level` 四选一；`not-verified` 的条目不得作为对外承诺的依据
   （方案 §7.9：无证据即不承诺）。

## 1. 目录

| 文件 | 内容 |
|---|---|
| [README.md](README.md) | 本文件：定位、字段、枚举、覆盖契约、checker 规则、维护流程。 |
| [whitelist.json](whitelist.json) | 白名单本体：一个数组，每条是一项合法差异（31 条，见 §6）。 |
| [schema/whitelist.schema.json](schema/whitelist.schema.json) | 白名单的 JSON Schema；自足，不用 `$ref`/`$defs`/`anyOf`/`allOf`。 |
| [schema/divergence-class.schema.json](schema/divergence-class.schema.json) | `divergence_class` 的取值域，枚举与三类定义同文件，防止枚举和定义漂移。 |
| [golden/](golden/) | 5 条示例：3 条合法（含 1 条 `baseline: not-applicable`）、2 条被拒（各带 `reason` 说明为何被拒）。 |
| [tools/platform_check.py](tools/platform_check.py) | checker：schema 校验、id 唯一、枚举合法、spec_ref 解析、例外通道、覆盖率报告。 |
| [tools/test_platform_check.py](tools/test_platform_check.py) | 变异测试：17 条，每条只破坏一件事，checker 必须失败。 |

白名单是**数组**而不是对象：没有元数据头，也没有版本号字段。版本靠仓库历史与 `id` 稳定性承担，
避免出现「声明了但没人校验」的字段。

## 2. 字段

每条必须有的 10 个字段（schema 的 `required`）：

| 字段 | 类型 | 含义 |
|---|---|---|
| `id` | string | 稳定标识，`platform.<slug>`；一经引用不得改名。 |
| `capability` | string | 能力名，`<域>.<能力>`。同一能力可以有多条分歧（例如秘密存储与它的降级链）。 |
| `ios` | string | iOS 基线的机制与所在位置，必须点名具体 API 或文件角色。 |
| `android` | string | Android 映射及其语义约束。 |
| `divergence_class` | enum | 三类之一，见 §3。 |
| `rationale` | string | 为什么这条差异合法、语义等价声明是什么、哪些行为不许放宽；≤ 1000 字符。 |
| `spec_ref` | string | `spec/<tree>/<file>.md §N` 形式，见 §5。 |
| `android_mechanism` | string | 具体 Android API 名（ASCII）；`os-forced` 条目必须有。 |
| `evidence_level` | enum | 四级之一，见 §4。 |
| `baseline` | string | Swift 基线实现的仓库相对路径，或 `not-applicable`，见 §6。 |

只有 `baseline: not-applicable` 的条目可以再带 3 个例外字段：`justification_class`、
`evidence`、`approved_by`。**其它条目带上它们就是 fail**——例外字段不是注释位。

schema 用 `minLength`/`maxLength` 把长句压住：`rationale` 超过 1000 字符说明这条差异没有被想清楚，
应该拆条目而不是写长文。

## 3. divergence_class：三类合法分歧

三类之外没有第四类。「实现方便」「还没做」「Kotlin 更顺手」都不是类别。

| 取值 | 定义 | 判据 |
|---|---|---|
| `os-forced` | **OS 强制**：iOS 侧依赖的某个 OS 机制在 Android 不存在或语义不同，必须换机制实现同一可观测语义。 | 语义等价是义务；只能换机制，不能放宽语义。 |
| `hardware-absent` | **硬件不存在**：iOS 设备上可靠存在的硬件/安全单元在 Android 不存在或为可选件。 | 必须诚实降级、标注当前级别，并把失效路径写进可用性矩阵。 |
| `policy-forbidden` | **分发政策禁止**：OS 提供了该机制，但分发渠道政策禁止使用或禁止某种用法。 | 只能引导用户或改走别的实现路径；差异由政策造成，不是 OS 能力缺失。 |

枚举与定义同源于 `schema/divergence-class.schema.json`：`enum` 是取值域，`x-class-definitions`
是上面这张表的机器可读版本。`x-` 前缀的成员是**注记**：校验器一律忽略，不参与校验，也不能
引入新的结构语义；checker 只把它们当文档，并检查 `whitelist.schema.json` 的
`divergence_class` 枚举与 `enum` 逐字相同（防漂移）。

## 4. evidence_level：四级证据

| 取值 | 含义 | 允许的表述 |
|---|---|---|
| `device-gate` | 必须在真机矩阵上实测，通过后才可对外承诺（方案 §7.9 的真机 gate）。 | 「机制已定，承诺待实测」。 |
| `emulator-probe` | 可在模拟器/CI 探针中复现（对表 iOS 的 channel 探针行）。 | 「机制与行为已在探针上验证」。 |
| `spec-only` | 依据来自仓库内规范或常量，不需要平台实测（如 budgets 的 tier 表）。 | 「规范即判据」。 |
| `not-verified` | 方案未给出可引用来源，或机制尚未定稿；按未验证处理。 | 「只登记分歧，不作承诺」。 |

`not-verified` 的条目**必须在 `rationale` 里写明「未验证」**以及升级路径（要测什么、由哪个
工作项产出）。checker 会检查这个关键词；本期 5 条，见 §9。

等级不能「就地升级」：从 `emulator-probe` 升到 `device-gate` 要有对应的实测记录，
从 `not-verified` 升级要先补来源或先把机制定稿。

## 5. spec_ref：出处必须可解析

`spec_ref` 形如 `spec/v1/wal.md §5.2`，checker 做四件事：

1. 路径必须是仓库相对路径、不许含 `..`、不许绝对路径；
2. 文件必须存在；
3. 文件必须是 Markdown（`*.md`）；
4. 节号必须能作为**标题**找到：`## 5.2`、`### 5.2`、`## B.9`、`## 10.` 都算命中；
   但 `§5` 不会命中 `### 5.2 ...`（子节不算父节）。

引用 `spec/platform/` 自身被拒绝：白名单不能给自己当出处。

选择节号的原则是**语义锚点**，不是「文件里出现过这个词」：写 `fsync` 的条款、规定 reclaim token
是唯一凭据的条款、规定状态机边的条款，才是对应条目的出处。

## 6. baseline 与 `baseline: not-applicable` 例外通道

`baseline` 是 Swift 基线实现的仓库相对路径，checker 验证文件存在。它回答的问题是：
「这条差异改动的是哪一份基线行为？」

Swift 侧**无法承载**的平台机制走例外通道（方案 §5.3-1）：把 `baseline` 写成 `not-applicable`，
并补齐三个字段，缺一即 fail：

| 字段 | 要求 |
|---|---|
| `justification_class` | `os-mechanism-absent` / `hardware-absent` / `distribution-policy` 三选一。 |
| `evidence` | 为什么 Swift 侧无法承载，以及可核对的仓库锚点（≥ 20 字符）。 |
| `approved_by` | 批准该例外的角色或工作包标识；不写个人姓名、不写邮箱。 |

例外通道只对「Swift 侧复现不了」开放，不对「基线还没做」开放：方案的例子是 renderer-gone、
无 drain 窗口、无 audio session。本期 4 条走例外通道，各自类别不同：

- `platform.keystore-downgrade-chain`（`hardware-absent`）：三级降级链只在 Android 存在；
- `platform.fgs-turn-notification`（`os-mechanism-absent`）：iOS 没有 FGS 通知；
- `platform.post-notifications-degraded`（`os-mechanism-absent`）：iOS 没有通知不可见即禁用后台通道的耦合；
- `platform.battery-exemption-policy`（`distribution-policy`）：iOS 没有可申请的电池优化豁免。

## 7. 覆盖契约

`tools/platform_check.py` 用常量钉住必填清单，缺一条即 fail，并在覆盖率报告里逐条打印。

### 7.1 十三个 OS 原语（`REQUIRED_PRIMITIVES`）

方案 §3.2 当前是 **12 行数据行**。其中 `Network.framework` 行同时点名 `NWListener` 与
`NWPathMonitor` 两个 iOS 原语、对应两个不同的 Android 机制（Ktor embedded server 与
`ConnectivityManager.NetworkCallback`），白名单按机制拆成两条，因此 `REQUIRED_PRIMITIVES`
是 **13 条**。若上游把 §3.2 补成 13 行，向常量追加对应 id 即可；常量条数与 13 不一致时 checker
自己也会 fail（防止有人改常量绕过覆盖）。

| §3.2 行 | 条目 | 证据等级 |
|---|---|---|
| 1 `fcntl F_FULLFSYNC` | `platform.fsync-epoch-close` | device-gate |
| 2 Keychain（SecItem*） | `platform.keychain-credential-store` | device-gate |
| 3 `Network.framework` NWListener | `platform.nwlistener-loopback` | emulator-probe |
| 3 `Network.framework` NWPathMonitor | `platform.nwpathmonitor` | emulator-probe |
| 4 `URLSession` | `platform.urlsession-http-client` | emulator-probe |
| 5 `WKScriptMessageHandlerWithReply` | `platform.script-message-reply` | not-verified |
| 6 `WKURLSchemeHandler` | `platform.url-scheme-handler` | emulator-probe |
| 7 ScenePhase | `platform.scene-phase` | emulator-probe |
| 8 `ProcessInfo.thermalState` / 电池 | `platform.thermal-battery` | emulator-probe |
| 9 `BGTaskScheduler` + BGContinuedProcessingTask | `platform.bgtask-drain-window` | device-gate |
| 10 静音音频保活 | `platform.audio-keepalive` | device-gate |
| 11 Lockdown Mode 诚实报告 | `platform.lockdown-report` | not-verified |
| 12 `BudgetTable` tier | `platform.budgettier-memory` | spec-only |

### 7.2 六条承接项（`REQUIRED_MANDATES`）

| 方案位置 | 条目 | 说明 |
|---|---|---|
| §7.3 Keychain 降级链 | `platform.keystore-downgrade-chain` | StrongBox → TEE → 加密文件；与 §3.2 第 2 行是同一能力的两条分歧。 |
| §9.4 第 1 行 FGS 通知展示回合与进度 | `platform.fgs-turn-notification` | 前台服务必须带通知。 |
| §9.4 第 2 行 预测性返回 | `platform.predictive-back` | 返回语义一致，手势形态按平台惯例。 |
| §9.4 第 3 行 networkSecurityConfig | `platform.network-security-config` | 只对 loopback 主机窄豁明文。 |
| §9.4 第 3 行 WebView 版本门槛 | `platform.webview-version-gate` | 第 3 行含三个子项，Keystore 子项由 §3.2/§7.3 覆盖，这里新增两条。 |
| §7.7 `POST_NOTIFICATIONS` 降级 | `platform.post-notifications-degraded` | 拒绝通知只降级呈现，不使承诺失效。 |

另有 1 条不属于必填清单的登记：`platform.battery-exemption-policy`（§7.5，Play 版不申请电池优化
豁免）。它是 `policy-forbidden` 的唯一实例，保留它是因为「三类枚举」不应有一类是空的。

## 8. checker 强制项

`python3 spec/platform/tools/platform_check.py --root .` 按顺序强制：

1. 两个 schema 只使用受支持的 JSON Schema 子集（`$ref`/`$defs`/`anyOf`/`allOf` 等一律拒绝；
   `title`/`description`/`x-` 注记除外，它们不参与校验）；
2. `divergence_class` 枚举与 `divergence-class.schema.json` 逐字一致；
3. 白名单根是数组、`minItems` 满足、每条通过 item schema；
4. `id` 唯一（重复即 fail，不做后者覆盖前者的静默处理）；
5. `divergence_class` / `evidence_level` / `justification_class` 合法；
6. `spec_ref` 解析到真实文件与真实节号标题；
7. `baseline` 路径存在；`not-applicable` 必须带三字段，且三字段只能在 `not-applicable` 上出现；
8. `os-forced` 条目必须带 `android_mechanism`，机制必须是 ASCII API 名（「平台相关」这类空话被拒）；
9. `not-verified` 条目的 `rationale` 必须写明「未验证」；
10. 覆盖：`REQUIRED_PRIMITIVES` 13 条、`REQUIRED_MANDATES` 6 条，缺一即 fail；
11. golden：`intent: legal` 必须通过全部规则，`intent: rejected` 必须至少违反一条且 `reason` ≥ 20 字符。

## 9. 运行与输出契约

```bash
python3 spec/platform/tools/platform_check.py --root .
python3 -m unittest discover -s spec/platform/tools -p 'test_*.py' -v
```

输出契约：**每个被检查的文件一行** `ok` 或 `FAIL`，然后是覆盖率报告、枚举/证据/基线直方图，
最后一行是「N files checked, M whitelist entries, K failures」。失败退出码 1，全绿退出码 0。
checker 只读仓库，不写文件，不需要网络，只用 Python 标准库。

本期 `not-verified` 有 5 条，理由写在各自 `rationale` 里：

- `platform.script-message-reply`：桥协议未定稿（方案 §4.4、§11-R2 要求写进 spec 并覆盖桥帧金标）；
- `platform.lockdown-report`：Android 侧没有 Lockdown 等价物的可引用来源，等引擎 spike 给出实测口径；
- `platform.pclink-identity-seed`、`platform.pclink-foreground-relay`、`platform.pclink-doze-network`：Android PCLink（`PC-20261112-pclink-android`）尚无真机证据，C2–C5 落地并真机实测后升级。

## 10. 维护流程

- **加条目**：先确认差异确实落在三类之一，再补 `spec_ref` 与 `baseline`；找不到真实节号说明该差异
  还没有规范锚点，应先进 spec 修订流程（方案 §5.3-2），而不是先写白名单。
- **改条目**：`id` 不改；语义变了就新增条目并把旧条目标为已被取代（写在 `rationale` 里）。
- **删条目**：只有差异消失（两端语义合一）才删，并在最终消息里说明；不允许因为「不想解释了」删。
- **升级证据等级**：`not-verified` → `emulator-probe` 要有探针，`emulator-probe` → `device-gate`
  要有真机记录；等级不能跳级。
- **白名单不是实现许可**：登记一条差异只说明它合法，不说明它已实现；实现态由各平台树自己的
  status 表承担。

## 11. 边界

- 不复制 Android 文档正文，不写协议规范：协议正文在 `spec/v1/`，本树只写「哪一条差异、凭什么、
  证据到哪一级」。
- 不写外部链接与个人邮箱：API 名按公开名称书写，出处靠仓库内 `spec_ref`。
- 不做「语义等价」的散文论证：语义等价声明压在一句话内，写不下就说明该拆条目。
- 不替代 conformance：本树证明差异合法，conformance 证明语义一致，两者都要在 CI 里跑。

## 12. 已知开放项

1. message 桥协议缺规范条文（方案 §4.4、§11-R2）：`platform.script-message-reply` 因此停在
   `not-verified`，桥帧金标落地后回填来源并升级。
2. Lockdown 报告的 Android 口径未定（方案 §3.2 第 11 行、§6.2）：等引擎 spike 给出 WebView
   版本门槛与失败报告的实测数据。
3. §3.2 的表格随方案演进：当前 12 行数据行，本树按「一机制一条目」拆成 13 条原语（见 §7.1）。
   上游若补成 13 行，向 `REQUIRED_PRIMITIVES` 追加对应 id；条数变更必须显式，缺一即 fail。
4. thermal/battery 的显式映射表（含未取到信号时的默认档）尚未落成条文（方案 §7.10）。
5. `POST_NOTIFICATIONS` 降级的文案与呈现待 UI 规范（方案 §9.2-5、`spec/ui/v1`），本树只钉语义。
6. CI 接线：`scripts/ci/` 不在本工作包的授权范围，把 checker 加进 `check.sh` 需要共享区 PR。
7. 例外通道的 `approved_by` 目前是工作包标识（`P0-H2`），P0 评审时由平台 owner 复核并替换为
   角色名（仍不写个人姓名）。
8. 方案 §6.2 有两条按未验证处理的说法（Android 17 起回环明文自动豁免、WASI 的 sleep/poll 是否走
   `Atomics.wait`），它们不属于 §3.2 原语，因此没有独立条目；前者的口径已写进
   `platform.network-security-config` 的 `rationale` 并声明本条不依赖它，后者属引擎 spike 范围。

## 13. The whitelist is a contract of divergences, not an SPI index

An entry names a place where Android and iOS legitimately differ. It does **not** promise that a
shared abstraction will hide the difference. During the port, six `:platform` SPI interfaces
(`Clock`, `LifecycleSignals`, `Durability`, `SecureStore`, `EngineHost`, `Notifier`) were built and
measured against this file: they fully express **7** entries, partially express **2**, and have no
business expressing the other **13**.

That ratio is the expected outcome, not a gap. The 13 live where the divergence actually is:

| Entry group | Owner | Why it is not an SPI |
| --- | --- | --- |
| `nwlistener-loopback`, `urlsession-http-client`, `ws-upgrade-query-token`, `coep-cross-origin-isolation` | `:net` | The transport *is* the divergence; an abstraction over it would just re-export Ktor/OkHttp configuration |
| `script-message-reply`, `url-scheme-handler`, `webview-version-gate` | `:engine` | These are WebView API facts; wrapping them would hide the very API surface the port must reason about |
| `bgtask-drain-window`, `audio-keepalive`, `budgettier-memory` | app / host layer | They are lifecycle and policy, owned by the app that holds the permission |
| `predictive-back`, `network-security-config`, `battery-exemption-policy` | `:app` / manifest / distribution | Declarative or navigation-level, not runtime services |

**The rule.** An SPI exists only when **two or more modules** need the same OS primitive. A
divergence that only one module acts on belongs in that module, documented by its whitelist entry.
Adding a second group of SPI interfaces to "cover" the other 13 would be abstraction for its own
sake, and the plan's §5.1 already says this layer is the one deliberate departure from the 1:1
mirror — a reason to keep it small, not a licence to grow it.

Five entries stay `not-verified` (the three PCLink ones were added by `PC-20261112-pclink-android`) and one stays `spec-only`; the audit above does not change that.



## Android module mapping inventory

`android-module-map.json` is the reviewed P08/P12 inventory mapping every
`Sources/PhoneDSH*` directory to an Android package and Gradle module or to an
explicit absence. Its schema is `schema/android-module-map.schema.json`. As
semantic constraints in addition to schema, every `swift` name must be unique
and the version must be encoded as the integer JSON literal `1`, not `1.0`.
Both mapping and vector schemas must pass the existing platform schema linter
before validation; unknown or unsupported schema keywords fail closed.
`mapped` means a corresponding source package exists, not that all behavior is
complete; `target` is an unwired partial implementation, not a feature; `absent`
has no claimed package or module. The Markdown table in `android/README.md` is
a human-readable projection and must match the inventory exactly. The existing
`android/tools/structure_check.py` checks source directories and the table in
both directions, duplicate rows, valid statuses, actual Gradle module and
production Kotlin package paths; no new source directory may be silently
accepted merely by changing a count. The shared positive/negative scenarios are
`golden/android-module-map-cases.jsonl`. Changes to this inventory require
review of actual platform code; this is not evidence of a working device or of
P0 UI parity.
