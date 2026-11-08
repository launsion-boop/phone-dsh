# 页面结构门：登记文件与对称判定规则（normative）

Status: P09 · 补充 [README](README.md) §1 的页面结构契约，由 `tools/page_structure_check.py` 与 `tools/extract_ios_pages.py` 执行。

`pages/` 下的登记文件各管一类，不能互相代替；都由 `page_structure_check.py` 读取，过期（不再匹配任何观测项）或 `reviewBy` 已过即失败：

| 文件 | 登记什么 | 必填 |
|---|---|---|
| `_whitelist.json` | 平台被迫差异（引用 `spec/platform/whitelist.json` id） | id、两侧 label |
| `_baseline.json` | 已知 Android parity 债（棘轮，只减不增） | lane、reason |
| `_android-only.json` | iOS 基线没有、Android 必须有的**整页** | owner、理由 |
| `_android-only-items.json` | iOS 页有、但 Android 同页**多出一项**（section 或 action）且该项是平台或职责划分逼出来的 | `page`、`kind`、`title`/`label`、`reason.{baselineLacks, androidNeeds, withoutIt}`（三问都要答）、`owner`、`reviewBy`；可选 `note` |
| `_unrecognized.json` | 人工判定为无法静态比较的项（如只含运行时文本的无标题错误分组） | owner、reviewBy、reason |

`_android-only-items.json` 的准入规则：只登记**平台或数据来源不同**导致的必需项，并且该项必须在发货路由里真能出现——
(1) `androidNeeds` 必须指向 iOS 不存在的约束（跨进程快照读、系统 API、宿主职责划分），"Android 也想要"不算；
(2) 若 iOS 已有等价恢复/入口（如同页 `.refreshable`），Android 多出的按钮不算必需；
(3) 只在可空回调下渲染、而发货路由（`PdshNavHost`）从不传入该回调的控件不能登记——源码里有、屏幕上没有；
(4) 产品取舍（某端多做或少做一个功能）不进本文件，记 baseline §7 GAP 并写 owner。
checker 把登记项计为 Android 期望项、在报告里逐条打印三问，Android 页不再出现即 `android-only-stale`。

对称判定（两端用同一把尺子）：

- **内嵌子页**：README §1 点名随父页实现的子页（`EMBEDDED_HINTS`），若没有自己的契约（Android 无同名屏），其被父页呈现时的动作并入父页契约（`presentedBy`），与 private 呈现结构体同一规则；其 Section 标题仍作为 `subpages[].sections` 打印、两端都不比较。
- **数据标签**：iOS 侧 `Button { Text(profile.name) }` 一类无字面文案的控件记为 unlabelled、不比较；Android 侧标签或分组标题若**只由宿主数据构成**（不含任何字面文案、`UiStrings`、常量、`native(…)`、`.format(…)`，如 `row.name`、`field.title`、`if (draft.isEmpty()) field.title else "$draft"`），同样不比较，在报告 `data-labelled Android items` 中列出。含静态文案却无法解析的表达式仍记 `unresolved`。合同里有字面文案而 Android 没画出来，仍报 `missing-*`。
- **双文案控件**：iOS `testing ? "正在测试…" : "测试连接"` 记为一个控件（`label`+`labelAlternatives`）；Android `if (c) UiStrings.A else UiStrings.B` 只在合同里某一个控件同时拥有这两种文案时才解析为该控件，否则仍记 `unresolved`。条件为 `cb == null` 的分支是禁用说明，不是动作。
- **导航栏文字按钮**：`SettingsNavAction` 只在页框 `trailing = { … }` 槽里算动作（对应 iOS `.confirmationAction` 文字按钮）；`leading` 槽是返回/关闭字形与图标按钮，不比较。
- **许可目录**：`LicensesPage` 是平台许可目录：扁平 List 内只有 `LabeledContent(名称, value: 许可)` 条目与打开随包许可全文（`Bundle.main.url(forResource:withExtension: "txt")`）的 `NavigationLink` 行时判为 single-region，条目与全文链接都是平台目录内容，记录但不比较；出现 Section、按钮或其他子视图即退回 `unmodeled`。
