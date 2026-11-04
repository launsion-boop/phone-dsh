# L27 — 三条「不是页面缺陷」的分歧：机制登记与未决项

本车道只动登记文件，不动页面（`Sources/**`、`examples/**`、`android/**`、
`plugins/**`、`shell/**`、`scripts/ci/**` 与契约正文均未编辑）；契约只由
`spec/ui/v1/tools/extract_ios_pages.py` 重生成。

## 0. 结论

| # | 分歧（`--baseline` 口径的 new finding） | 归属机制 | 状态 |
|---|---|---|---|
| 1 | `native-configuration` `extra-section '手机 Worker 限制'` | `_whitelist.json`（**唯一合法**），但 `spec/platform/whitelist.json` 没有可引用的 id | **未登记**，见 §2 |
| 2 | `native-plugin-inventory` `missing-section 'This iPhone Worker has no pnpm, …'` | 同上；且这条的契约字面量本身抽错了，见 §2.4 | **未登记**，见 §2 |
| 3 | `workspace-folders` `extra-action '重试'` | `_android-only-items.json` | **已登记**，`--page workspace-folders` 已 0 divergence，见 §3 |

任务书把第 1、2 条都记在 `native-plugin-inventory` 名下；实际是**两个页**：

* `native-configuration`：标题对——契约 `iPhone Worker 限制`（`NativeConfigurationPage.swift:41`）
  vs Android `手机 Worker 限制`（`UiStrings.CONFIGURATION_LIMITS_SECTION`）。`missing-section`
  那一半早已在 `_baseline.json` 里（known row），所以这次新出现的只有 `extra-section`。
* `native-plugin-inventory`：契约 `:55` 的无标题组只有一行
  `Text(nativePluginManagementMessage("This iPhone Worker…"))`（`NativePluginInventoryPage.swift:56`），
  Android 用 `UiStrings.PLUGIN_INVENTORY_MANAGEMENT_NOTICE`（「这台手机没有 pnpm…」，宿主可用
  `PluginInventoryFacts.managementNotice` 覆盖）。只有 `missing-section` 一半。

两者确实是同一条规则的两面：**同一事实、平台恰当措辞**（Android 不能把「iPhone」当成本机）。

## 1. 开工/收工时的口径（快照，`--baseline`）

开工（18:43）：`--baseline` 口径 11 条 new。收工（18:53）：**3 条 new，0 stale**。11 → 3 里只有
1 条是本车道闭合的（`workspace-folders` 重试）；其余 7 条是页面车道在并行闭合的，收工时都已从工作树
消失：`egress-allow-list 恢复成默认的`、`native-device-connection 解除该设备的会话映射`、
`native-device-session 正在读取…`、`chat 完成`、`chat 刷新`、`native-automation 修改计划时间`、
`native-automation 保存`。收工时剩下的 3 条 = 本车道的 2 条平台措辞 + 页面车道的
`session-artifacts 分享`。全量（`--strict`）是 **20** 条（17 条 baseline-known + 3 条 new）。
（页面车道仍在改，数字是 18:53 的快照；本车道的不变量只有「第 3 条已清零、第 1/2 条未登记」。）

## 2. 第 1、2 条：四个机制逐一否掉，结论是「今天没有可用机制」

`spec/ui/v1/README.md:88` 写死了分工：「平台被迫差异**只走** `pages/_whitelist.json`（每条 MUST 引用
`spec/platform/whitelist.json` 的 id）」。所以问题不是「挑一个最像的」，而是这条规则要求的那条
platform id 存不存在。

| 文件 | 语义 / 代码 | 对第 1、2 条为什么不行 |
|---|---|---|
| `_android-only-items.json` | extractor 的 `merge_android_only_items()` 把它**追加**成契约里的 section/action，checker 当成「Android 应有」 | 只会**加**期望项：第 1 条会让契约同时要求 `iPhone Worker 限制`（基线那半仍在）和 `手机 Worker 限制`，页面得同时画两个标题；第 2 条连形状都没有（只有 `section`（必带 `title`）和 `action`，表达不了「无标题组里的一行」）
| `_android-only.json` | 只登记**整屏**（无契约的 `*Page`），只被 `unmapped-android-screen` 读 | 两页都有契约，且各有 `android` 映射；这不是整屏缺失 |
| `_unrecognized.json` | 「结构上无法静态比较」；`apply_unrecognized()` 按 (page, kind, name) 吞掉 finding | 这两条**是可以静态比较的**：两边都是字面量，比较已经发生，结论就是「不同」。用它登记等于绕开 `_whitelist.json` 的 platform-id 要求，正是任务书说的「硬塞」；README 也不允许（平台被迫差异只走 `_whitelist.json`） |
| `_whitelist.json` | `load_whitelist()` 要求 `platformRef ∈ spec/platform/whitelist.json`；`apply_whitelist()` 把该 finding 记成 `whitelisted` | **形状正确、内容缺失**：见下 |

### 2.1 为什么 `_whitelist.json` 现在写不进去

`spec/platform/whitelist.json` 有 25 条，capability 全是 OS/框架机制：`durability.*`、`security.*`、
`network.*`、`engine.*`、`lifecycle.*`、`power.*`、`background.*`、`notifier.*`、`budget.*`，UI 侧只有
`ui.safe-area`（insets 机制）、`ui.navigation-back`（预测性返回）、`ui.file-preview-text-extensions`
（UTType 扩展）——**没有任何一条是「机型称谓/文案」**。按任务书硬约束，我不能在
`spec/platform/whitelist.json` 里造 id。

即使 id 有了，还有第二个坎：`divergence_class` 只有三个合法值，定义都在机制层
（`os-forced` = iOS 依赖的 OS 机制在 Android 不存在/语义不同；`hardware-absent`；`policy-forbidden`），
而 `platform_check.py` 的 `check_mechanism()` 对 `os-forced` **强制要求**一份具体的
`android_mechanism`（具体 API 名，禁止「平台相关/待定」）。文案差异两端都没有需要替换的 API：
Android 侧只是 `UiStrings` 常量 + 宿主可覆盖的 `managementNotice`。用 `os-forced` 填
`android_mechanism = UiStrings.PLUGIN_INVENTORY_MANAGEMENT_NOTICE` 机械上能过，语义上是一句谎。

### 2.2 需要 owner 补的那条（二选一，然后才有 `_whitelist.json`）

**路线 A（推荐，语义最诚实）**：给 platform 白名单加一条平台措辞分歧，并决定它的
`divergence_class`——要么新增第四个类（`platform-forced-copy`，同时改
`spec/platform/schema/divergence-class.schema.json`、`whitelist.schema.json` 的 enum，以及
`platform_check.py` 的 `DIVERGENCE_CLASSES`），要么明确豁免 `android_mechanism`。条目草案：

```json
{
  "id": "platform.phone-worker-copy",
  "capability": "ui.platform-copy",
  "ios": "NativeConfigurationPage.swift:41 的 section 标题 `iPhone Worker 限制`；:42 与 NativePluginInventoryPage.swift:56 用 nativePluginManagementMessage 渲染 `This iPhone Worker …`（NativeChatPreferences.swift:337-339 的中文是 `此 iPhone Worker …`）",
  "android": "UiStrings.CONFIGURATION_LIMITS_SECTION = `手机 Worker 限制`；UiStrings.PLUGIN_INVENTORY_MANAGEMENT_NOTICE = `这台手机没有 pnpm…`，宿主可用 PluginInventoryFacts.managementNotice 覆盖",
  "divergence_class": "<待 owner 定：新类 platform-forced-copy，或 os-forced + 文案常量作 android_mechanism>",
  "rationale": "同一事实（这台手机的 Worker 没有 pnpm/execa/子进程安装环境、清单只读、安装与启停在桌面 DSH）在两端的措辞必须说的是用户手里这台设备；Android 说 iPhone 是假话。允许放宽的只有机型称谓，事实集、只读语义与「去桌面 DSH 安装」的指向不允许放宽。",
  "spec_ref": "spec/ui/v1/README.md §5",
  "android_mechanism": "UiStrings.PLUGIN_INVENTORY_MANAGEMENT_NOTICE",
  "evidence_level": "spec-only",
  "baseline": "examples/probe-app/PhoneDSHProbe/NativePluginInventoryPage.swift"
}
```

`spec_ref` 之所以选 §5（「平台差异白名单」）而不是 §1：这是**平台差异**，§1 只列页面。但要注意
`ui_check.py::check_divergences()` 把 README §5 的 `platformDivergences` 死钉在**固定 8 条**
（缺一条、多一条都失败），所以「用 §5」意味着 §5 的正文/表格与 `ui_check.py` 的 8 条上限同时要动
——这已经超出本车道可写范围，属于 ui/平台规范 owner 的决定。若不想动 §5，退而引用
`spec/ui/v1/README.md §1`（两页都在表里，机制上能过 `platform_check`，但 §1 并没有写这条规则）。

**路线 B（不改 platform 规范）**：把基线文案改成平台中立（`NativeConfigurationPage.swift:41`
标题与 `NativePluginInventoryPage.swift:56` 句子），两端都说同一句中立话。它要改
`examples/probe-app/**` 并重跑 extractor，不在本车道可写范围，而且等于改 iOS 产品文案——应由
owner 决定，不能由登记车道顺手做。

### 2.3 若将来走 `_whitelist.json`，三条都要成对落地

```json
[
  {"id": "native-configuration.worker-limits-title-ios", "page": "native-configuration",
   "kind": "missing-section", "name": "iPhone Worker 限制", "side": "ios-only",
   "platformRef": "platform.phone-worker-copy", "owner": "ui-contract", "reviewBy": "2027-06-30",
   "reason": "…"},
  {"id": "native-configuration.worker-limits-title-android", "page": "native-configuration",
   "kind": "extra-section", "name": "手机 Worker 限制", "side": "android-only",
   "platformRef": "platform.phone-worker-copy", "owner": "ui-contract", "reviewBy": "2027-06-30",
   "reason": "…"},
  {"id": "native-plugin-inventory.worker-limits-notice", "page": "native-plugin-inventory",
   "kind": "missing-section", "name": "This iPhone Worker has no pnpm, execa or subprocess installation environment. Plugins and bundles can be viewed here; install, enable and disable them in desktop DSH.",
   "side": "ios-only", "platformRef": "platform.phone-worker-copy", "owner": "ui-contract",
   "reviewBy": "2027-06-30", "reason": "…"}
]
```

两个必须一起做的配套动作（都不在本车道可写范围）：

1. `_baseline.json` 里 `native-configuration / missing-section / iPhone Worker 限制` 这条 known row
   必须同时删掉。`apply_whitelist()` 在 Rule 5 之前吞掉 finding，一旦只 whitelist 不改 baseline，
   那条 baseline 会变成 **stale** 直接 FAIL；而只白掉 `extra-section` 一半、把 `missing-section`
   继续留在 ratchet 里，等于把一对差异登记成两套说法，也不该做。
2. 第 2 条的平台中性化/白名单落地前，先看 §2.4 的契约字面量问题。

### 2.4 第 2 条还有一个契约侧的事实：那个字面量不是页面真正渲染的字符串

`NativePluginInventoryPage.swift:56` 是
`Text(nativePluginManagementMessage("This iPhone Worker has no pnpm, …"))`；helper 在
`NativeChatPreferences.swift:337-339`：

```swift
func nativePluginManagementMessage(_ english: String) -> String {
    NativeText("此 iPhone Worker 没有 pnpm、execa 或子进程安装环境。…", english)
}
```

extractor 的 `first_label()`（`extract_ios_pages.py:310`）取「区间里第一个字符串字面量」，于是把
**helper 的英文实参**记成了该行的 `label`（`extraction: "syntax"`）。中文 iOS 实际渲染的是
`此 iPhone Worker …`。所以这条 finding 现在是拿「Android 的中文句子」去比「iOS helper 的英文实参」，
而不是比 iOS 真正的渲染文本（英文实参只在英文 locale 才出现）。结论不变（Android 的措辞确实不同），
但**不能把一个中文基线并不渲染的字符串当成判据 whitelist 掉**，否则登记本身写错。建议契约车道二选一：
把 helper 调用建模为表达式
（`labelExpr`，criterion 变 `first-row-expression`），或取 `NativeText` 的中文字面量；字面量一变，
§2.3 第 3 条 `name` 必须跟着改。`native-configuration` 的标题（`NativeText("iPhone Worker 限制", …)`）
不受这个 bug 影响，它的中文字面量本来就是对的。

### 2.5 结论

**第 1、2 条现在没有合适的机制可登记。** `_whitelist.json` 是唯一语义正确的文件，但它的前置
（`spec/platform/whitelist.json` 的 id + 能表达「平台措辞」的 `divergence_class`）今天不存在；
另外三个文件都会把事情做错（§2 表格）。所以本车道**没有**往任何文件里写这两条，也没有动
`_baseline.json` 来「压绿」。需要 owner 先做 §2.2 的决定。

## 3. 第 3 条：`workspace-folders` 的重试

**它属于 `workspace-folders`。** 页面在 `WorkspaceFoldersPage.kt:379` 用
`SessionFailureLine(message = state.failure, retryLabel = UiStrings.RETRY, onRetry = onRetry, …)`
画失败行；`state.failure != null` 时 `WorkspaceFoldersScreenState.from`（`:219`、`:224`）把状态置为
`FAILED`，`:229`–`:231` 明说不保留任何行（留着旧表就是在断言它是当前值）；页面在 `:388` 因此不画列表，
失败时页面上只剩失败行 + 重试。契约没有它是因为基线页（`NativeShell.swift:319`）直接画
`management.workspaces`（`:320`、`:326`，进程内 `DSHManagementModel.shared`），没有失败态。

登记到 `_android-only-items.json`（已写入）的理由按三问写，全部落在**页面级事实**，不引用任何
共享包装器（`SessionFailureLine` 只是画法；它改名/删除不影响这条理由）：

```json
{
  "page": "workspace-folders",
  "kind": "action",
  "label": "重试",
  "reason": {
    "baselineLacks": "WorkspaceFoldersPage (NativeShell.swift:319) draws `management.workspaces` from the in-process `DSHManagementModel.shared` (`:320`, `:326`); its body has no failure state, so it has no retry to offer",
    "androidNeeds": "the Android rows are host facts carried by a snapshot read across the process boundary: `WorkspaceFoldersScreenState.from` maps `snapshot.failure` to `FAILED` and deliberately keeps no rows, so the page must be able to re-read in place",
    "withoutIt": "a failed read leaves only the failure line on an otherwise empty page; dismissing it does not restore the rows, so the user has to leave and re-enter the page to get a list back"
  },
  "owner": "android-ui",
  "reviewBy": "2027-01-31"
}
```

为什么不是 `_whitelist.json`：这不是「同一个契约项在两端被迫不同」，而是**数据源不同导致的追加**
（iOS 进程内模型 / Android 跨进程快照），正是 `_android-only-items.json` 的 note 定义的用途；
extractor 会把它合进契约，页面将来若删掉重试，checker 会报 `android-only-stale` 提醒删登记。

## 4. 「今晚有一条登记的理由写错了」的定位

### 4.1 主要嫌疑：`_android-only.json` 的 `ToolsPage`（本车道不动）

`_android-only.json:24-27`（今晚 18:24 写入）把 `ToolsPage.kt` 登记成一张 Android-only **屏**；理由大意是
「VIEW 已搬到 `PDSHShellPage.kt`，这个 composable 没人调；它留着是因为 reducer 是整页的状态层，
删掉 public composable 属于没有调用点可依据的 API 变更」。问题在于：被登记的东西是**旧的页面视图包装器**，不是屏——`ToolsPage.kt:273` 的
`public fun ToolsPage(` 与路由用的 `PDSHShellPage`（`PDSHShellPage.kt:97`，`PdshNavHost.kt:434`）
是同一个 reducer（`ToolsScreenState`/`ShellLocalState`/`ShellUiEvent`）的两份 body；
`PDSHShellPageTest.kt:5` 自己写「`ToolsPageTest` keeps the older `ToolsPage` view」。删掉那个旧
body 不会删 reducer（reducer 就在同一个文件里、`PDSHShellPage` 还在用），唯一的调用点是
`ToolsPageTest.kt:62`。也就是说：它是个**将被删掉的包装器**，正确处置是「删旧 body + 迁移/删测试 +
删这条登记」，而不是用「API 变更」把它留在 `_android-only.json` 里当屏。

**本车道不修**：删登记会让 checker 在 `ToolsPage()` 还在时立刻报 `unmapped-android-screen`，要修就得
动 `android/**`（本车道禁写）。正确顺序是 android 车道先删旧 body 与 `ToolsPageTest`，随后
spec 侧删这条 entry。这条不影响当前 gate（`ToolsPage` 被登记，`unmapped-android-screen` 已清）。

### 4.2 顺手修掉的第二条：`native-workbench` 的 `重试` 理由（本车道已改）

`_android-only-items.json` 里原文写的是「NativeWorkbenchPage.swift reads its folder list from local
state」——**假的**：`NativeWorkbenchPage.swift:6-30` 是一个组合包装器，`NavigationStack/VStack` + 文件/命令
`Picker`（`:16`），把 `FilesPage`（`:24`）和 `PDSHShellPage`（`:26`）嵌进来，自己没有任何数据读取。
已改成「组合包装器、自己不做读取、因此没有失败态」，并重跑 extractor；gate 结果不变（该页本来就 0）。

如果 §4.1 那条是任务书说的「即将被删掉的包装器」，它和 §4.2 是两件事：前者需要 android 车道先删
旧 body，后者是纯理由修正、已完成。

## 5. 复跑结果

```
$ python3 spec/ui/v1/tools/extract_ios_pages.py
… 32 pages, 109 sections, 340 rows, 277 actions          # exit 0（277 = 登记前 276 + workspace-folders 重试）

$ python3 spec/ui/v1/tools/extract_ios_pages.py --check
contracts up to date                                      # exit 0

$ python3 spec/ui/v1/tools/page_structure_check.py --root . --page workspace-folders
page-structure: ok (0 divergences, 0 whitelisted)         # exit 0
  android-only: 切换 / 删除 / 重试

$ python3 spec/ui/v1/tools/page_structure_check.py --root . --page native-plugin-inventory
page-structure: FAIL (1 divergence(s)…)                   # exit 1 —— §2 的那条，未登记
  - missing-section 'This iPhone Worker has no pnpm, …'

$ python3 spec/ui/v1/tools/page_structure_check.py --root . --page native-configuration
page-structure: FAIL (2 divergence(s)…)                   # exit 1 —— §2 的那对，未登记

$ python3 spec/ui/v1/tools/page_structure_check.py --root . --page native-workbench
page-structure: ok (0 divergences, 0 whitelisted)         # exit 0（理由已修正）

$ python3 spec/ui/v1/tools/page_structure_check.py --root .
page-structure: FAIL (20 divergence(s)…)                  # strict：17 条 known + 3 条 new

$ python3 spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json
page-structure: FAIL (3 new divergence(s) outside the baseline)   # 0 stale
  - native-configuration  extra-section '手机 Worker 限制'
  - native-plugin-inventory  missing-section 'This iPhone Worker …'
  - session-artifacts  missing-action '分享'           # 页面车道的，不是本车道

$ python3 -m unittest discover -s spec/ui/v1/tools -p 'test_page_structure_check.py'
Ran 58 tests … OK                                         # 登记不破坏 checker 自测
```

`native-plugin-inventory` 与 `native-configuration` 的 `--page` 复跑**本来就会红**：§2 的两条没有合法
容器，按任务书「不要硬塞」，它们以 divergence 的原样留着。

## 6. Open questions

1. **平台措辞该不该有 `divergence_class`？** §2.2 的路线 A/B 需要 platform/ui 规范 owner 拍板；
   在此之前第 1、2 条只能红着。若走 A，还要决定 §5 是否加第 9 条（`ui_check.py` 把
   `platformDivergences` 钉死在 8 条，需要同步改 `ui_check.py`，本车道不可写）。
2. **`_baseline.json` 的配套删除**：`native-configuration / missing-section / iPhone Worker 限制`
   必须与白名单**同一次**落地删掉（否则 stale FAIL）。本车道不可写 `_baseline.json`。
3. **契约字面量 bug（§2.4）**：`nativePluginManagementMessage` 的英文实参被当成渲染文本。修它会改变
   这条 finding 的 `name`，白名单/`_unrecognized` 条目都得引用新字面量。属契约车道。
4. **`ToolsPage` 的处置顺序（§4.1）**：android 车道删旧 body + `ToolsPageTest` → spec 侧删
   `_android-only.json` 的 entry；当前登记是「先让 gate 绿」的权宜，不是屏的登记。
5. **checker 的显示 bug（只影响可读性，不影响判定）**：`page_structure_check.py` 在
   `single-region` 的打印里用了 `contract.get('sectionNote')`（`:1790`），而 `contract` 是上一个循环
   （`check_provenance`，`:1707`）留下的**最后一个契约**的变量——所以 `native-workbench` /
   `settings-about` / `workspace-folders` 三页都打印了同一个（workspace-folders 的）note，
   `native-workbench` 契约里真正的 note 是「NavigationStack/VStack: a segmented mode switch over two
   embedded pages; no group header」。修法是用 `contracts[summary['page']]`。属 checker owner。
