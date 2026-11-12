<!-- SPDX-License-Identifier: MIT -->

# PC-20261111-bot-identity-reclaim — 会话身份登记失效后的自动重认领与可见状态

```yaml
change: PC-20261111-bot-identity-reclaim
contracts: [P05, P09, P26]
status: implemented
breaking: false
version_decision: "No wire version change: the route, method, request/response fields, error code and `phone/botClaimSession` RPC are unchanged. The App re-claims through the existing RPC and the Worker's single retry sends the same `/identity/register` body. Old/new pairs fail closed exactly as before; a Worker without the retry still receives the re-claimed credential for its next registration."
base: de47c0ee
contract_revision: spec/bot/v1/mcp-endpoint.md@bot-identity-reclaim-v1 + spec/ui/v1/pages/bot-info.md@bot-info-bridge-status-v1
```

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 2026-11-11 22:01–22:54 现场：同一 Bot 会话在 22:02 shell 正常，约 41 分钟无工具调用（锁屏/切后台）后，所有需要身份登记的工具返回
  `[identity-bridge] App MCP did not accept the call registration: unauthorized`，多次复测不自愈；`read/grep/glob/web_fetch` 正常。
  现况：前台 resume 会重建 WKWebView/Worker，Worker 的
  `botOwnedSessions` in-memory map 为空；宿主 `PhoneDSHHost` 的 resume 路径
  (`bootRuntime`) 不发布 `.restarted`，而 `BotRuntimeComposition` 只监听
  `.webContentTerminated`/`.restarted`，于是它仍认为宿主 `sessions` 里的当前
  token 已被认领。旧 transport 会自行重连新 Worker（`ChannelDSHTransport`
  `waitForChannel`），所以对话继续可用，但每个登记请求都不带 token，宿主只能
  回 `unauthorized`；宿主也没有重签或重认领，故不自愈。期望：新的 Worker boot
  被 `.workerHello` 的新 `boot_id` 识别后，App 在下一回合前重认领所有在用会话；
  并在单次 `unauthorized` 上做一次有界自愈，失败给人话。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元
  `bridge-heal`（worktree `dsh-work/bridge-heal`，分支
  `bot/identity-bridge-heal`，base `de47c0ee`）兼任四角色。
- **Owning contract / schema / fixtures.** P05／P16／P25／P26 的共同 owning
  doc：`spec/bot/v1/mcp-endpoint.md` §2、§3、§4、§6；P09：
  `spec/ui/v1/pages/bot-info.md` §在场状态。无 schema/golden 变更；共享
  fixtures 沿用 `spec/bot/v1/golden/*` 与现有 identity/egress 测试。
- **受影响 producer / consumer.** producer：Worker `plugins/bot-runtime`
  (`identity-bridge.ts`, `approval-gate.ts`)；Swift 宿主
  `Sources/PhoneDSHBot/MCP`、`Sources/PhoneDSH/PhoneDSHHost.swift`、App
  composition (`examples/probe-app/PhoneDSHProbe/Bot/**`)；consumer：Bot
  模型工具面、Bot 信息页「在场」区。Android/HarmonyOS 无 Bot runtime，不跟进。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| 触发信号 | 仅 planned restart / `webContentTerminated` 会通知 Bot runtime → `park()`/`resume()` boot 的新 Worker 也以既有 `.workerHello` 的新 `boot_id` 触发重认领；不改 host event shape（P05 §3/§4）。 |
| 重认领时机 | App 在 Worker 重启后“下一回合前”懒认领 → 新 boot 绑定时 `reclaimOwnedSessions()` 重认领全部在用会话；token 失效时用同一 session 的 kind/capabilities 重签，不延长 TTL（P05 §3）。 |
| 单次 `unauthorized` | 直接失败关闭 → App 仅在自身 credential map 仍持有该 `sessionId` 当前 token 时，通过既有 `phone/botClaimSession` 重认领；Worker 重读 in-memory map 后**只重试一次**；仍失败回一句人话，工具不执行（P05 §3、P26）。 |
| 跨 session token | `unauthorized` → 保持 `unauthorized`；若请求 token 解析为另一个 session，不重认领、不重试成功。body `sessionId` 从来不是身份证据（P05 §3）。 |
| 状态可见 | 无宿主记录、无 UI 行 → 宿主内存记录最近一次失败的时间/错误码/session（无 token/参数/body），成功清除；Bot 信息页「在场」区一行只读 `桥状态`，无错误不显示占位（P09）。 |
| 审批错误文案 | `[structural approval gate] unattributed ...` → 同一 gate 的 `unattributed` 映射为「这个对话与 App 的身份登记已失效…请稍后重试或重新打开对话。」（P09／P26；不改结构/错误码）。 |
| `phone/botClaimSession` | `{sessionId, sessionToken?}` 原样；Worker 对同一 session 的后续 claim **覆盖**旧 token（实现已如此，本次新增回归测试）。 |

自检（`spec/README.md` §5.1）：没有新 route、method、字段、header、错误码或
schema；`unauthorized` 仍是同一个失败形状；body `sessionId` 仍不是身份证据；
新行为只收紧（不再把空闲后的丢失 credential 当作永久失败），不回退任何现有
校验。

## 3. 兼容性

| Producer → Consumer | 支持／拒绝方式及理由；对应测试 |
| --- | --- |
| old App → new Worker | 老 App 不重认领；Worker 重试仍无 token，按原规则 `unauthorized` 失败关闭。没有数据损坏，也没有绕过身份。 |
| new App → old Worker | 老 Worker 不重试，但 App 在其第一次 `unauthorized` 时已通过既有 claim RPC 把当前 token 交回；下一次登记即可成功。若老 Worker 的 claim RPC 缺失，`gb-` 仍按原 `claimAcknowledged=false` 路径失败关闭。 |
| new App → new Worker | ① 首次登记带丢失 token；② 宿主持有该 session 当前 token 时重认领；③ Worker 重试一次成功；④ 宿主无当前 token、跨 session token、或重试仍失败时 `unauthorized` + 人话。 |
| persisted old data / rollback | 无持久化 token、无新 event、无 schema/DB 迁移；回滚旧 App/Worker 恢复旧行为。诊断仅在宿主内存，进程退出即消失。 |
| Android / HarmonyOS | 无 Bot runtime；不实现本契约。 |

**版本决定。** 非 breaking：所有 wire 形状不变，只有既有 `unauthorized` 前增加
App 侧重认领副作用和 Worker 的一次重试；老/新组合都按原规则 fail closed。

## 4. 分工与证据

- **实现路径.** Worker：`plugins/bot-runtime/src/{identity-bridge,approval-gate}.ts`；
  宿主：`Sources/PhoneDSHBot/MCP/{BotMCPRuntime,BotMCPHandler,BotMCPTypes,BotDSHRemoteRuntime}.swift`、
  `Sources/PhoneDSH/PhoneDSHHost.swift`；App composition／UI：
  `examples/probe-app/PhoneDSHProbe/Bot/{BotRuntimeComposition,BotRuntimeUnit,BotProductionServices,BotProductionUIAdapters,BotInfoPage}.swift`；契约：
  `spec/bot/v1/mcp-endpoint.md`、`spec/ui/v1/pages/bot-info.md`、`spec/README.md`。
- **共享 fixtures.** 无新增 schema/golden；identity/egress 现有 golden 与 WP3 Q3/Q4
  测试继续使用。
- **真实 producer/consumer 测试.**
  - TS `tests/bot-identity-approval.test.ts`：单次重认领重试、永久失败只重试一次并回人话、
    同一 session 第二次 claim 覆盖 token、unattributed 人话；
  - Swift `BotSessionCredentialLifecycleTests`：Worker 重建后首登记 `unauthorized`→
    App 重认领当前 token→重试成功；跨 session token 不重认领；stale token 在
    `reclaimOwnedSessions()` 下重签并重新 claim；
  - Swift `PhoneDSHHostTests.testResumePublishesANewWorkerHelloAndBootID`：
    park/resume 的新 Worker HELLO 带新 `boot_id`，即 composition 的触发信号；
  - Eval composition E2E：真实 Host/Worker，park→resume 后 bash 仍成功执行。
- **Exact commands → 结果.**
  - `swift build --disable-sandbox` → PASS.
  - `swift test --disable-sandbox --filter 'PhoneDSHBotTests|PhoneDSHGatewayTests|PhoneDSHLoopbackTests|PhoneDSHTests'` → 1376 tests, 1 failure（已知基线
    `ProbeScenePhaseWiringTests.testScenePhaseOnChangeLivesOnlyInAppEntries`）。
  - `cd plugins && npm run typecheck` → PASS；`node scripts/run-tests.mjs "tests/bot-*.test.ts"` → 123 pass / 0 fail / 1 skip（124 total）。
  - `python3 spec/bot/v1/tools/validate_vectors.py`、`python3 spec/tools/bot/check_golden.py --root .` → PASS。
  - `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-bot-eval-catalog` → PASS。
  - `bash examples/probe-app/scripts/copy-bundle-assets.sh ...` + `bash scripts/ci/check.sh --only phone-bundle-fresh` → PASS（5 fresh / 1 absent web-boot）。
  - iOS App `xcodebuild build ...` → BUILD SUCCEEDED。
  - Eval selftest `BOT-SELFTEST-RESTART`（改为 `park_resume` + bash）→ PASS；
    `BOT-SELFTEST-MEMORY-ERASE` → PASS（新增的自动 hello 恢复会与 session-epoch
    eraser 自己的 park/start 重绑竞争，已在 eraser 手动重绑期间抑制自动路径）。
    完整 selftest 18 个场景中 17 PASS / 1 FAIL（`BOT-SELFTEST-PROACTIVE` 为
    routine `advance_clock` 超时，同代码的并行运行也失败；与身份登记无关）。
  - Eval 产品场景 `catalog.json`，`--upstream mock` → 14/14 PASS。
  - Eval iOS Simulator `BotCompositionE2ETests.testProductionCompositionUsesRealHostAndWorker`
    → 编译成功，测试启动被本机沙箱的 PTY 限制拒绝（`Pseudo Terminal Setup Error`），
    记 INCOMPLETE，不据此声称模拟器通过。
- **剩余风险.** iOS 真机锁屏/后台保活、系统回收时机与 WKWebView 进程回收仍为
  NOT_RUN；本单元只在 macOS 测试与真实 Host/Worker mock 上游上验证，不能据此
  声称真机成功。`BOT-SELFTEST-PROACTIVE` 的 routine 超时是既有/环境问题，需要
  单独排查。另一个 Bot 的 session token 仍无法冒用（WP3 Q3/Q4 保持）。
