# L20 — `phone-hygiene` 逐条分诊与修复（2026-11-01）

> 范围：`scripts/ci/hygiene.py`（规则）与 `docs/receipts/**`（真实泄漏）。
> 结果：`148` 条 → **`0` 条**。其中 `72` 条是扫描器规则误报，`76` 条是真实泄漏，已脱敏。
>
> 注：任务书里的「`139` 条 = 75 + 64」只统计了 `home-path` 与 `hostname`；同一次扫描还产出
> `5 email` 与 `4 banned-word`，合计 `148`。本文按 `148` 分诊。

**本文刻意不逐字复现泄漏值。** 复现就等于再泄漏一次，而且会让本文自身触发同一条规则
（`Tono·Live` 中间的 `·` 就是为此加的）。需要定位时看表里的 `file:line`。

---

## 1. 汇总

| 类别 | 条数 | 判定 | 处理 |
|---|---:|---|---|
| A 必需的 XML 命名空间 | 11 | 误报 | 规则：`xmlns` 属性值不是主机名 |
| B macOS/iOS app bundle 名 | 13 | 误报 | 规则：`.app` 前的 CamelCase 标签是文件名 |
| C Java/Kotlin 包路径前缀 | 6 | 误报 | 规则：后面还有 `.identifier` 的点分名是包名 |
| D 公开第三方站点（截图样例/研究引用/规范链接） | 26 | 误报 | 规则：`CITED_PUBLIC_HOSTS` 值级白名单 |
| E 不可路由 IPv4 字面量 | 4 | 误报 | 规则：私网/环回/RFC 5737/占位八位组 |
| F 省略占位符（`https://…`、`/Users/...`、无 host URL） | 3 | 误报 | 规则：省略号与空 host 无可判定对象 |
| G 文档示例路径 `<root>/home/a` | 2 | 误报 | 规则：符号根后接的是相对拼接 |
| H 保留文档域 `feeds.example.org` | 1 | 误报 | 规则：补上 RFC 2606 的 `example.org` |
| I 主机名大小写 `API.deepseek.com` | 1 | 误报 | 规则：主机名不区分大小写 |
| J 图片 `@2x` 资源名 | 3 | 误报 | 规则：`@2x.<图片扩展名>` 是文件名 |
| K Kotlin `this@label` 标签接收者 | 1 | 误报 | 规则：关键字局部部不是邮箱 |
| L 测试夹具 `user@api.example.com` | 1 | 误报 | 允许表：与既有 `password@api.example.com` 同型 |
| **小计（误报）** | **72** | | 规则修正 |
| M 真实 home 绝对路径 | 72 | **真实泄漏** | 脱敏 + 生成器根因修复 |
| N 内部代号 | 4 | **真实泄漏** | 脱敏 + 生成器根因修复 |
| **小计（真实）** | **76** | | |
| **合计** | **148** | | **现为 0** |

被 A–L 排除的 71 条已逐条归因到唯一一条新规则（`xmlns=11`、`bundle=13`、`cited-public=26`、
`dotted-continuation=6`、`unroutable-ipv4=4`、`empty/elided=2`、`reserved-.example.org=1`、
`allowlist-case=1`、`email×3`、`home×4`），**没有一条落到「无法解释」**。

---

## 2. 误报（A–L，规则修正）

### A. 必需的 XML 命名空间 — 11 条

`xmlns:android="http://schemas.android.com/apk/res/android"`。XML 解析器把它当不透明标识符，
从不发起网络请求。10 个 `AndroidManifest.xml` + 1 个 vector drawable
（`android/app/src/main/...`、`android/domain/...`、`android/dsh/...`、`android/engine/...`、
`android/lib/...`、`android/platform-android/...`、`android/testkit/...`）。删掉这行 Gradle 立刻拒绝合并资源。

### B. macOS/iOS app bundle 名 — 13 条

`.app` 既是真 gTLD 又是 bundle 后缀。区分靠「`.app` 前的标签是否 CamelCase」——
源码里的主机名写小写，bundle 名带产品名大写（与 `looks_like_package_path` 已有的
「大小写即证据」判据同源）。

代表：`android/tools/ios-baseline-capture.sh:167`（`PhoneDSHProbe.app`）、
`CLOSEOUT_PLAN.md:22` 与 9 个 `reports/*.json:15`（`Google Chrome.app`）、
`preview-research/03-ios-platform.md:754`（`Probe.app`）。

**不误伤**：小写的真 `.app` 域名（如 `getlocalcode.app`）走 D 类值级白名单；任意其他小写
`.app` 域名仍会被抓（自测有反向断言）。

### C. Java/Kotlin 包路径前缀 — 6 条

`LoopbackModelProxy.kt:48,49`、`LoopbackService.kt:55`（`import io.ktor.utils.io.readAvailable`）；
`ModelGatewayCredentialProviderTest.kt:12,20`、`MiniHttpServer.kt:11`（`import com.sun.net.httpserver.HttpServer`）。
匹配到的点分名后面还接着 `.identifier`，说明它是包路径前缀。

### D. 公开第三方站点 — 26 条

三组，全部是**故意**出现在文本里的公开站点，且都是**值级**白名单（同一行换一个主机名照样报）。

- **截图样例 12 条** `android/lib/src/androidTest/.../SettingsParitySamples.kt:82-95` —— 出网白名单
  页面的截图需要一屏像样的样例条目（`api.open-meteo.com`、`api.github.com`、`pypi.org`、
  `registry.npmjs.org`、`cdn.jsdelivr.net`、`unpkg.com`、`api.duckduckgo.com` …）。该文件**未跟踪**。
- **研究文档引用 9 条** `docs/research-office-conversion-2026-10-29.md:19-44` —— 许可/价格/产品页。
- **规范链接 5 条** —— `webidl.spec.whatwg.org`、`streams.spec.whatwg.org`
  （`plugins/worker-entry/src/jsc-compat.ts:83,97`、`docs/receipts/android-port-2026-10-31.md:2147,2158,2166`）。

### E. 不可路由 IPv4 — 4 条

`GatewayRuleTest.kt:377,378`（`http://10.1.2.3/x`，单测通配符）、
`preview-research/03-ios-platform.md:205`（`http://192.168.1.5:3000`，文档举例「用户输入的局域网 IP」）、
`03-ios-platform.md:344`（`http://192.168.x.x`，占位八位组不是数字）。

判定依据：`hostname` 规则问的是「这个名字指向读者够得着、且能归因到某人的基础设施吗」。
环回/链路本地/RFC 1918/RFC 5737/占位都不是。**公网 IPv4 仍然会报**（自测有断言）。

### F. 省略占位符 — 3 条

`preview-research/02-official-dsh.md:215`（`https://…`）、`01-current-ios.md:156`（`/Users/...`，
作者已手动省略过）、`spec/v1/golden/gateway/fail-003.json:12`（`"url": "https://:443/v1/models"`，
剥掉端口后 host 为空串）。**`spec/**` 未改动。**

### G. 文档示例路径 — 2 条

`android/core/.../VfsPath.kt:51` 与 `android/tools/structure_check.py:93`，命中的都是
`<root>/home/a` 的后半段。`<root>` 是符号根，它后面那段是相对拼接，不是绝对路径
（`structure_check.py` 的注释原文就写着 "continuation, not a new path"）。

### H–L. 单条类

| 类别 | 文件:行 | 命中 | 为什么不是泄漏 |
|---|---|---|---|
| H | `.../DailyBriefPageTest.kt:48` | `https://feeds.example.org/rss.xml` | RFC 2606 保留域；只是原来漏了 `.example.org` 后缀 |
| I | `.../EgressAllowListPageTest.kt:321` | `API.deepseek.com` | 就是允许表里那个官方 provider host，只是大写；主机名不区分大小写 |
| J | `ios-session-audit/05-timeline.md:130`（同行 2 次）、`prompts/05-timeline.md:29` | `running-whale@2x.png` | Apple 的 `@2x` 倍图后缀，不是邮箱 |
| K | `android/lib/src/main/.../ThinkingPill.kt:209` | `this@drawWithContent.drawContent()` | Kotlin 标签接收者 |
| L | `.../EgressAllowListPageTest.kt:338` | `user@api.example.com` | 断言「带 userinfo 的条目必须被拒」的夹具；与允许表已有的 `password@api.example.com` 同型同域 |

---

## 3. 真实泄漏（M / N）——已脱敏

### M. home 绝对路径 — 72 条 / 24 个文件

三组前缀：`$HOME/Documents/Codex/…/deepseek-harness` 50 条、`$HOME/Desktop/TonoTeam/phone-dsh`
20 条、`$HOME/.dsh` 2 条。全部落在 `docs/receipts/**`：

| 文件 | 条数 | 处理方式 |
|---|---:|---|
| `screens/official/manifest.json` | 22 | **重新生成**（生成器脱敏） |
| `screens/official/manifest.md` | 18 | **重新生成**（生成器脱敏） |
| `screens/official/reports/*.json`（9 个） | 9 | 按新 `cdp-capture.mjs` 的语义改写 |
| 其余 13 个 md/json | 23 | 文本替换，行数不变 |

**替换语义**：`/Users/...` 与 `/home/...` 的**用户名那一段**→ `~`（不是删掉整条路径）。
`~/Documents/Codex/...` 仍然写着「这个文件在 home 下的哪个位置」，只是不再写「哪台机器上的谁」，
而且记录下来的命令依旧可跑（`--official-repo ~/Documents/...`）。

**证明**：13 个纯文本文件逐个核对 `new == 把用户名那一段替换成 ~ 之后的 old`，**行数全部不变**
（459/418/334/374/351/163/244/90/234/1065/103/590/719 行，改前改后逐个相等）。
9 个 `reports/*.json` 用结构化 diff 核对：只有 `screenshot.path`、`boot.bodyTextHead`、
`boot.bodyTextRedactions` 三个字段变，其余字段断言逐字节相等。

### N. 内部代号 — 4 条 / 2 行

`manifest.json:1086`（`observedBodyTextHead`）与
`reports/official-session-chat-long-user-turn-…json:55`（`boot.bodyTextHead`），各 2 次。
两处都在**捕获到的页面正文**里，不是渲染出来的视口内容。

**截图里代号可见吗：不可见。** 该状态在清单里就写作「滚动到 turn tail」，PNG 显示的是长 prompt
的 JSON 尾部；代号在正文开头约 100 字符处，在视口之上。截图顶部标题只显示
`You are the evidence-re…`。因此 **PNG 不受影响，无需重做捕获**。

处理：`→ <internal-project>`，并在两处产物里各留一条记录（见 §4）。

---

## 4. 上游根因：生成器不再写绝对路径

手改产物而不同时改生成器，下次捕获会再漏一次。本次两层都改了：

**新增 `scripts/ios-parity/golden/redactions.mjs`**（唯一一处定义）：
`redactText` / `countRedactions` / `redactionReport` / `assertRedacted`。
两条规则都是**文本级、全量**（不是字段清单），所以以后新增字段也漏不出去：

1. `home-path`：`/Users/...`、`/home/...` 的用户名那一段 → `~`；已经是 `/Users/...` 的省略标记保持不动。
2. `internal-codename`：内部服务拼写 → `<internal-project>`（在源码里运行时拼装，代码文件本身不携带该字面量）。

`assertRedacted` 是 **fail-closed**：`redactText` 幂等，所以「再跑一次没有变化」就等于「已经没有可脱敏的目标」；
不满足就 throw，`main()` 的 catch 会 `process.exit(1)`，**写不出脏产物**。

**`write-manifest.mjs`**：写 `manifest.json` / `manifest.md` 之前对整份文本做 `redactText` + `assertRedacted`；
并把命中次数记进 `manifest.redactions`，`manifest.md` 里生成 `## 发布脱敏` 小节。

**`cdp-capture.mjs`**：`screenshot.path` 改成 `basename`（随 PNG 一起提交的 repo 相对路径）；
`boot.bodyTextHead` 同样脱敏，并在命中时写 `boot.bodyTextRedactions`。

**重新生成并验证**：先用 HEAD 版生成器做一次往返，证明重建的输入是忠实的 ——
`manifest.json` **逐字节相同**（`manifest.md` 只差末尾一个空行，因为已提交的那份被手工削过）。
再用新版重新生成，结构化 diff 显示**只有**路径字段变成 `~/`、代号变成 `<internal-project>`、
新增 `redactions` 块，其余每一个字段都不变。

运行时产物现在是：

```json
"redactions": [
  { "kind": "home-path",         "with": "~",                 "replacements": 21 },
  { "kind": "internal-codename", "with": "<internal-project>", "replacements": 2  }
]
```

---

## 5. 已知盲区

这条门禁**不覆盖**下面几类，写在这里是为了让以后的人不要以为它是万能的：

| 盲区 | 原因 | 残余风险 |
|---|---|---|
| **真实内网地址**（RFC 1918 里的具体地址） | `hostname` 规则按「是否指向读者够得着的、可归因的基础设施」判定；私有段不满足。本轮 4 条命中全是单测/文档举例/占位符，没有别的仪器能把「私有字面量」与「私有字面量」分开 | 一个真的内网地址（如 `10.<实际段>.<实际段>.<实际段>`）以后不会再被这条门禁抓到。要覆盖它需要另立规则（例如只在 `Tests/**`、`docs/**` 放行私有段，生产源码仍报） |
| **大写标签的 `.app` 主机名** | `.app` 既是 gTLD 又是 bundle 后缀，靠「`.app` 前的标签是否 CamelCase」区分 | 一个真叫 `Foo.app` 的公网域会被漏掉（实际极罕见；小写 `.app` 域仍覆盖） |
| **包名形态的真主机名** | 匹配后紧跟 `.identifier` 视为包名前缀 | 一个真主机名后面正好接 `.something` 会被漏掉 |
| **`xmlns` 属性值里的主机名** | namespace URI 不可解析，不存在这种泄漏 | 无实际风险 |
| **家目录之外的绝对路径** | 只匹配 `/Users/...`、`/home/...` 前缀 | `/opt/...`、`/Volumes/...`、Windows 盘符路径不覆盖 |
| **被 `.gitignore` 忽略的未跟踪文件** | 扫描集是 `git ls-files --cached --others --exclude-standard` | 构建产物里的泄漏不会被看到（这是有意的） |

---

## 6. 复跑

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export PATH="/opt/homebrew/opt/node@22/bin:$PATH"

bash scripts/ci/check.sh --only phone-hygiene           # PASS
bash scripts/ci/check.sh --only phone-gate-contracts   # PASS（ProductionScanTests 随之转绿）
python3 scripts/ci/selftest.py HygieneTests            # 5/5
```

`phone-gate-contracts` 里的 `ProductionScanTests` 断言的就是「生产树干净」，所以它只会在 M/N
真正修好之后转绿——之前它一直是红的，且与本轮扫描器改动无关（HEAD 上就已失败）。
