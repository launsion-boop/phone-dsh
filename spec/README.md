# phoneDSH 協議基線與變更協作

Status: normative index（索引本身是規範；各協議的欄位、位元組與狀態機仍由 owning contract 定義）
Baseline revision: 2（2026-11-03）。初次盤點 public main `fe33f75f46e970c051668027d85e9748b8f591ce`；
每次任務另記自己的 base/head，不要求停留在此 commit。

本頁回答四個問題：**哪些東西算協議**、**每個協議的唯一權威在哪**、**改了哪些路徑就碰到哪個協議**、
**改協議時誰做什麼、交什麼證據**。協作規則的唯一來源是 [AGENTS.md](../AGENTS.md)；`CLAUDE.md`
透過 `@AGENTS.md` 匯入同一份。本頁不複製任何協議內容，只登記與連結。

## 1. 什麼算協議

只要另一個模組、另一種語言、另一個進程、另一個版本的自己，或磁碟上的舊資料會讀到它，就是協議：

- 跨進程／跨語言訊息：frame、HTTP 路由與 header、postMessage／WKScriptMessage、JNI／FFI、Remote API。
- 持久化格式：WAL、manifest、journal、ledger、`/dsh/home/*.json`、UserDefaults 中的 JSON、image 產物。
- 啟動與環境：URL 參數、`PDSH_*` 環境變數、注入的全域變數、init 幀。
- 可觀察的狀態轉移與承諾：ACK 時機、重試、取消、恢復、idempotency、錯誤碼。
- 跨模組公開 API（Swift `public`、Kotlin 跨 Gradle module、TS 跨 plugin export）。

函式內部、單一模組私有、無任何可觀察行為差異的重構不是協議變更。

## 2. 權威層級與狀態詞彙

- **規範**：登記的 normative 文件決定語義，JSON Schema 決定形狀，golden 決定具體編碼與邊界案例。
  三者衝突就是缺陷，必須在同一變更中修正並說明相容性，不可自行挑一份當準。
- **參考實作**：Swift 是第一個在真機上證明行為的地方，但**不是**定義。Kotlin／TS／Rust 與 Swift
  不一致時，對照規範判斷誰錯；規範沒寫清楚就是規範缺陷，先補規範。
- **code contract**：尚無語言無關規範的邊界，以登記表指定的**單一源檔**為權威；另一端必須跟隨它。
  只有出現獨立版本需求或第三個實作時，才抽出 schema。
- **權威缺失**：代碼引用了不存在的規範（見 GAP-06）。在補齊之前，該邊界任何語義變更都必須先寫
  變更單並由協調者決定權威落在哪個檔案。

條款狀態統一使用以下詞彙（既有標記的對應見右欄；舊文件不強制一次改完，但新寫條款只用左欄）：

| 狀態 | 意義 | 既有標記 |
| --- | --- | --- |
| `implemented` | 所有登記端都已實作，有 runtime 測試證據 | 無自動對應；`[existing]`／`Status: normative` 只作查證線索，仍需逐端 runtime 證據 |
| `partial` | 部分端已實作；必須註明哪些端缺 | 無統一標記 |
| `target` | 已審定的目標設計，尚無或僅部分實作；**不可呼叫** | `[NEW]` |
| `draft` | 尚在討論，可以改；**不可依賴** | `draft`、`DRAFT`、`provisional: true` |
| `legacy` | 仍在線上運作、等待遷移的舊形狀；不得擴充 | `[legacy]` |
| `deprecated` | 有替代品，保留到登記的移除條件達成 | 無 |

規則：normative 條款不得依賴 `draft` 條款（現有違例見 GAP-09）；`target` 改為 `implemented`
需要每一端的 runtime 證據，不是 spec checker 通過。

## 3. 協議登記表

ID 是 review 與交接的索引，**不是 wire 欄位或能力名稱**。「角色」是任務中的責任，不預設綁定某個人；
協調者可兼任 contract owner，但實作者不得單方面重定義共同邊界。

### 3.1 已規範化的邊界（有 spec／schema／golden）

| ID／角色 | Owning contract | 實作端 | Runtime 證據（真正讀 golden 的測試） |
| --- | --- | --- | --- |
| P01 channel／wire owner | [v1/channel.md](v1/channel.md)、[v1/schema](v1/schema)、[golden/frames](v1/golden/frames) | Swift [PhoneDSHWire](../Sources/PhoneDSHWire/)、[ChannelServer](../Sources/PhoneDSHLoopback/ChannelServer.swift)、[PhoneDSHChannel](../Sources/PhoneDSH/PhoneDSHChannel.swift)；TS [channel](../plugins/channel/src/)；Rust [pdsh-wire](../shell/crates/pdsh-wire/) 經 [pdsh-jni](../shell/crates/pdsh-jni/) 供 Android；Kotlin [core/wire](../android/core/src/main/kotlin/com/phonedsh/wire/)（JNI 殼）、[dsh/host](../android/dsh/src/main/kotlin/com/phonedsh/dsh/host/) 的 HostHello／HostChannel／VfsFrames ；HarmonyOS partial `harmony/host-rust/src/ws.rs`, `harmony/host-rust/src/host.rs` | [Swift](../Tests/PhoneDSHWireTests/GoldenFrameTests.swift)、[TS](../plugins/channel/src/golden-frames.test.ts)、[Kotlin](../android/core/src/test/kotlin/com/phonedsh/wire/WireGoldenFramesTest.kt)、[Rust](../shell/crates/pdsh-wire/tests/golden_frames.rs)（`phone-rust-tests`；GAP-08 的其餘證據仍開放） |
| P02 VFS／WAL owner | [v1/wal.md](v1/wal.md)、[manifest schema](v1/schema/manifest.schema.json)、[golden/wal](v1/golden/wal) | Swift [PhoneDSHLog](../Sources/PhoneDSHLog/)、[WAL.swift](../Sources/PhoneDSHWire/WAL.swift)；Rust [pdsh-wal](../shell/crates/pdsh-wal/)；Kotlin [core/log](../android/core/src/main/kotlin/com/phonedsh/log/)、`dsh/host/{HostWal,WalUplink}.kt`；TS `plugins/channel/src/wal.ts` 只是**對拍 codec**，無生產消費者 ；HarmonyOS partial `harmony/host-rust/src/wal.rs`, `harmony/host-rust/src/overlay.rs` | Swift `WALTests`、`PhoneDSHLogTests`；Kotlin `NativeWalGoldenTest`；Rust [golden_wal.rs](../shell/crates/pdsh-wal/tests/golden_wal.rs)（`phone-rust-tests`） |
| P03 exec／journal／handoff owner | [v1/exec.md](v1/exec.md)、[v1/handoff.md](v1/handoff.md)、[v1/budgets.md](v1/budgets.md)、[golden/perturbations](v1/golden/perturbations) | Swift [PhoneDSHController](../Sources/PhoneDSHController/)、[Handoff](../Sources/PhoneDSH/Handoff/)、[Background](../Sources/PhoneDSH/Background/)、`PhoneDSHLedger.swift`、`PhoneDSHHost.swift`；TS `plugins/{exec-bridge,tool-journal,lifecycle-gate,subprocess-xl}`；Kotlin [android/controller](../android/controller/src/main/)、`android/dsh/.../dsh/{exec,journal,background}` ；HarmonyOS partial `harmony/host-rust/src/ws.rs`, `harmony/host-rust/src/wal.rs` | `StepMachineJournalContractTests`、`SideEffectLedgerTests`、`PhoneDSHDrainRecoveryContractTests`、`plugins/tests/journal-sync.test.ts`、Kotlin `PerturbationFixtureTest` |
| P04 page bridge owner | [v1/bridge.md](v1/bridge.md)、[bridge schema](v1/schema/bridge-message.schema.json)、[golden/bridge](v1/golden/bridge) | **規範大半是 `target`**。現行 handler：`pdshNativePreview`（Swift `Sources/PhoneDSHEngine/WebEngineNativePreview.swift` ↔ [protocol.ts](../plugins/phone-native-preview/src/protocol.ts)，`legacy` 形狀）、directory import、`xlEngine` console、`pdshMcpControl`（↔ `examples/probe-app/ProbeKit/MCPControlBridge.swift`）、`pdshOpenModelSettings`（**倉內無接收端**）；Kotlin `android/engine/.../{WebViewEngine,NavigationPolicy}.kt` ；HarmonyOS partial `harmony/entry/src/main/ets/host/HostBridge.ets`, `harmony/web/engine.mjs`, `harmony/web/product-worker.mjs` | bridge goldens **沒有任何 runtime 消費者**，只有 `bridge_check.py` |
| P05 HTTP／MCP gateway owner | [v1/gateway-security.md](v1/gateway-security.md)、[native MCP](v1/native-mcp.md)、[official DeepSeek web tools](v1/gateway-official-web.md)、[gateway schema](v1/schema/gateway-vector.schema.json)、[golden/gateway](v1/golden/gateway) | Swift [PhoneDSHGateway](../Sources/PhoneDSHGateway/)、Loopback HTTP（`HTTPTransport`、`StreamingForward`、`NativeMCP` 等；ChannelServer／WebSocket 屬 P01）；TS `plugins/llm-bridge`、`plugins/phone-mcp/src/{manager,schema}.ts`；Kotlin [android/net](../android/net/src/main/) ；HarmonyOS partial `harmony/entry/src/main/ets/host/HostHttpProxy.ets`, `harmony/entry/src/main/ets/host/HostModelAlias.ets`, `harmony/host-rust/src/http.rs` | Native MCP 有 Swift `PhoneDSHADBTests`；gateway vectors 只有 Kotlin `GatewayVectorConformanceTest` 讀取；Swift `Tests/PhoneDSHGatewayTests` 不讀 |
| P06 harness／host owner | [host/v1/README.md](host/v1/README.md)、[event-kinds](host/v1/event-kinds.md)、[host goldens](host/v1/golden)、[device task profile](device/v1/task-delegation.md)（`target`） | Swift [AgentHarness](../Sources/PhoneDSHAgentCore/AgentHarness.swift)、[DSH/](../Sources/PhoneDSHAgentCore/DSH/)、`PhoneDSHEvents.swift`；Kotlin `android/core/.../{agentcore,hostevents}`、`android/dsh/.../turn` ；HarmonyOS partial `harmony/entry/src/main/ets/host/TranscriptProjection.ets`, `harmony/entry/src/main/ets/host/HostService.ets` | 只有 Kotlin `HarnessKindClosureTest`、`HostEventKindSchemaTest` 讀 golden；Swift AgentCore tests 不讀 |
| P07 device／connector owner | host/v1 的 envelope／caps／receipt schema；[BLE Link profile](device/v1/ble-link.md)（`implemented`）；[Android BLE discovery](device/v1/android-ble-discovery.md)（`implemented`）；[Android standard GATT](device/v1/android-standard-gatt.md)（`implemented`；Link／任务仍 `target`）；[legacy identity preferences](device/v1/legacy-identity-preferences.md)（`legacy`）；[BLE identity proof](device/v1/ble-identity.md)（`target`；TOFU，非认证会话，GAP-16）；[LAN MCP profile](device/v1/lan-mcp.md)（`implemented`）；[device task profile](device/v1/task-delegation.md)（`target`）；[adapter draft](../docs/design/device-adapter-contract-draft.md)（`draft`） | Kotlin `android/domain/.../{device,connector}`；Swift `examples/probe-app/ProbeKit/Devices`、`Sources/PhoneDSHBLE`、`Sources/PhoneDSHLAN`、`Sources/PhoneDSHDeviceTasks`；C `firmware/components/pdsh_link_wire`、`firmware/esp32-reference`；Python `examples/lan-mcp-device`；Kotlin `android/app/.../probe/{AndroidBleScan,AndroidBleDevices}.kt` 已接入蓝牙设备页（扫描＋标准 GATT）；Android Link 与 LAN decoder 仍 `target` | Kotlin `DeviceCapabilitiesSchemaTest`；第三方傳輸與端到端回執不由 schema 保證 |
| P08 platform owner | [platform/README.md](platform/README.md)、[whitelist](platform/whitelist.json)、[iOS audio ownership](platform/ios-audio-session.md)、[Android module mapping](platform/android-module-map.json) | Swift OS API、`Sources/PhoneDSH/Background`、`ProbeKit/PhoneAudioSessionLease.swift` 与 app 的录音／保活调用方；Android `:platform`／`:engine`／`:net` ；HarmonyOS partial `harmony/entry/src/main/ets/entryability/EntryAbility.ets` | `platform_check.py`；Android mapping 由 `android/tools/structure_check.py` 及其测试核对；whitelist 不代替 conformance |
| P09 UI projection owner | [ui/v1/README.md](ui/v1/README.md)、[page source inventory](ui/v1/page-completeness.md)、[tokens](ui/v1/tokens.json)、[pages](ui/v1/pages)、[v1/trajectory.md](v1/trajectory.md) | iOS `examples/probe-app/PhoneDSHProbe`；Android `android/lib` ；HarmonyOS partial `harmony/entry/src/main/ets/ui`, `harmony/entry/src/main/ets/model/Contracts.ets` | Kotlin `UiStateProjectorGoldenTest`、`TrajectoryNormalizerTest`；`ui_check.py`、`extract_ios_pages.py` 及 mutation tests、`page_structure_check.py` |

### 3.2 只有 code contract 的邊界

| ID／角色 | 權威源檔（另一端跟隨它） | 另一端 | 證據與注意 |
| --- | --- | --- | --- |
| P10 workflow isolate owner | [workflow-worker/src/protocol.ts](../plugins/workflow-worker/src/protocol.ts) | 同 plugin 的 isolate | [workflow tests](../plugins/tests/workflow-worker.test.ts)。structured-clone；不傳 Agent、token、VFS handle、function；無 wire version，不冒稱 proto 1；DSH pin 升級會牽動型別 |
| P11 WASI VFS proxy owner | [vfs-protocol.ts](../plugins/wasi-toolbox/src/vfs-protocol.ts)、[types.ts](../plugins/wasi-toolbox/src/types.ts) | `vfs-server.ts`、`vfs-client.ts`、`sab-client-worker.ts`、`message-endpoint.ts` | [proxy](../plugins/wasi-toolbox/src/vfs-proxy.test.ts)、[SAB](../plugins/wasi-toolbox/src/vfs-sab.test.ts)。u32 長度是 **little-endian**，不可套用 P01 header |
| P12 native ABI owner | [shell/include/xzshell.h](../shell/include/xzshell.h) ；平台 host ABI [pdsh_host.h](../harmony/host-rust/include/pdsh_host.h)；[Android module mapping](platform/android-module-map.json) | Rust [pdsh-ffi](../shell/crates/pdsh-ffi/)、[pdsh-jni](../shell/crates/pdsh-jni/)；Swift [PhoneDSHShell](../Sources/PhoneDSHShell/)（含必須與 header 同步的 `PDSHShellCSurface.swift` stub）；Kotlin [android/shell](../android/shell/src/main/kotlin/com/phonedsh/shell/)、`core/wire/Native*.kt` ；HarmonyOS partial `harmony/host-rust/include/pdsh_host.h`, `harmony/entry/src/main/cpp/napi_init.cpp`, `harmony/entry/src/main/cpp/types/libpdshhost/index.d.ts` | 以 [Package.swift](../Package.swift)、Android build wiring、`android/tools/check-native-alignment.py` 判斷是否真的連結；[Android mapping projection](../android/README.md) 由 `android/tools/structure_check.py` 核對；source 存在不等於可用 |
| P13 plugin Remote owner | [phone-shell](../plugins/phone-shell/src/contract.ts)、[feature-admin](../plugins/phone-feature-admin/src/contracts.ts)、[phone-mcp](../plugins/phone-mcp/src/protocol.ts)、[directory-import](../plugins/phone-directory-import/src/types.ts)、`phone-model-config/src/remote.ts`、`surface-phone/src/management-remote.ts` | Web client、Swift `PhoneDSHWorkspaceImportSink.swift` ；HarmonyOS partial `harmony/entry/src/main/ets/host/HostService.ets` | [shell](../plugins/tests/phone-shell.test.ts)、[admin](../plugins/tests/phone-feature-admin.test.ts)、[mcp](../plugins/tests/phone-mcp.test.ts)、[import](../plugins/tests/phone-directory-import.test.ts)。至少 6 個 service 共用 `phone` namespace，**沒有方法名登記表**（GAP-10） |
| P14 DSH Remote mux owner | [ChannelDSHTransport.swift](../Sources/PhoneDSH/ChannelDSHTransport.swift)（`PhoneDSHMuxProtocol`，D22／D23） | `plugins/worker-entry/src/mux-{bridge,tunnel,json}.ts`；Swift `DSHRemoteTransport.swift`；Kotlin `android/dsh/.../turn/DshTurnClient.kt` ；HarmonyOS partial `harmony/web/engine.mjs` | `/api/remote.mux`：`x-pdsh-mux-id`、`x-pdsh-mux-op`、NDJSON、4 MiB 分塊。D21–D24 不在 v1 決策表（GAP-11） |
| P15 host 控制端點 owner | Swift `Sources/PhoneDSH/{PhoneDSHWorkerCommand,PhoneDSHRecovery,PhoneDSHDescendantDrain}.swift` | `plugins/surface-phone/src/*-controller.js` | `/api/pdsh-worker-command/execute`（receipt `pdsh-worker-command/1`）、`/api/pdsh-recovery/*`、`/api/pdsh-descendant-drain`；`PhoneDSHWorkerCommandTests`、`plugins/tests/worker-command-controller.test.ts` |
| P16 Worker 啟動契約 owner | Swift `PhoneDSHWorkerEnvironment`（[PhoneDSH.swift](../Sources/PhoneDSH/PhoneDSH.swift)）、`Sources/PhoneDSHEngine/WebEngineConfiguration.swift` | Kotlin `android/engine/.../WorkerEnvironment.kt`；Worker **兩份**解析器 `plugins/worker-entry/www/boot.js`、`src/web-boot.ts`，及 `src/entry.ts` ；HarmonyOS partial `harmony/host-rust/src/host.rs`, `harmony/web/product-worker.mjs` | URL 參數、init 幀、`PDSH_*` 環境變數（D24）、`__PDSH_*` 全域變數。兩份解析器必須同改 |
| P17 exec-bridge loopback owner | **權威缺失**：代碼引用的 `spec/exec-bridge-v1` 不在倉內（GAP-06）；現暫以 `plugins/exec-bridge/src/client.ts` 為準；`v1/exec.md` 登記 channel accelerator 的承載語義 | Swift `LoopbackServer.swift`、`ExecBridgeHosting.swift`、`PhoneDSHGateway/ModelGateway.swift`、`PhoneDSHSSH`、`PhoneDSHADB` | `/v1/hello`、`/v1/exec*`、`/v1/fs*`、`/v1/lifecycle`，NDJSON；SSH/SCP/ADB 經現有 EXEC bridge，不新增 envelope |
| P18 持久化設定 owner | [legacy identity preferences](device/v1/legacy-identity-preferences.md)；`/dsh/home/capabilities.json`：`plugins/worker-entry/src/capabilities.ts`；`mcp.json`：`plugins/phone-mcp/src/schema.ts`（`MCP_CONFIG_VERSION`）；`PDSH_MODEL_PROVIDER_JSON`：`plugins/phone-model-config/src/model-config.ts` ；Harmony 私有设置 [HostPersistence.ets](../harmony/entry/src/main/ets/host/HostPersistence.ets) | Swift `MaterializedInvariant.swift`、`ScenarioBudgets.swift`、`Sources/PhoneDSH/Phone*Settings.swift`；未查得 Kotlin 讀寫這三種設定的對應端 ；HarmonyOS partial `harmony/entry/src/main/ets/host/HostPersistence.ets`, `harmony/entry/src/main/ets/model/ProviderProfiles.ets` | 讀寫兩端、舊資料、降級一起評估；UserDefaults key 名也是協議 |
| P19 phone 工具 envelope owner | [PhoneToolEnvelope.swift](../examples/probe-app/ProbeKit/Capabilities/PhoneToolEnvelope.swift) 定義成功／失敗 envelope；Rust `shell/crates/pdsh-phone/src/lib.rs` 只定義 `phone.<tool>` 呼叫詞彙並原樣轉送結果 | Rust host bridge 消費結果；Kotlin `android/dsh/.../host/PhoneInfoTool.kt` 是獨立的 `phone info` exec 子集，回傳 exec outcome，不是同一 envelope 的實作 | Swift 成功回覆 `{ok,tool,egress,scope,data,nextCursor,truncated}`，上限 256 KiB；不據此宣稱 Kotlin envelope 對齊 |
| P20 Worker image 產物 owner | `plugins/scripts/pack-image.mjs`、[dsh-pin.json](../plugins/dsh-pin.json) | Swift `LoopbackServer.swift`；Kotlin `android/engine/.../*WorkerAssetSource.kt` ；HarmonyOS partial `harmony/tools/stage-runtime.mjs`, `harmony/host-rust/src/bundle.rs` | `manifest.json`、`sizes.json`、`config/vfs-manifest.json`、lazy／overlay tar |
| P21 render-media／office IR owner | [render-media-v1.md](v1/render-media-v1.md)（`draft`）、[office-ir-v1.json](v1/office-ir-v1.json) | Swift `PageSchemeHandler.swift`、`PageSurface.swift`、`ProbeKit/Office/OfficeIR.swift` | 無 gate 檢查；normative 文件已引用此 draft（GAP-09） |
| P22 scenario／perturbation fixtures owner | `spec/v1/schema/{scenario-*,perturbation,upstream-script}.schema.json` | `Sources/PhoneDSH{Scenario,Harness}`、`android/testkit`、`scripts/ci/scenarios` | `golden/upstream` 無 runtime 消費者 |
| P23 Android SDK toolchain listing owner | [SDK manager contract](toolchain/v1/sdk-manager.md)、[listing schema](toolchain/v1/schema/sdk-manager-listing.schema.json)、[listing vectors](toolchain/v1/golden/sdk-manager-listing.jsonl) | External Android SDK manager（不由倉庫控制）→ `android/tools/bootstrap-android-toolchain.sh` → `android/tools/test_gradle_build_inputs.py` | `android/tools/test_bootstrap_android_toolchain.py` 真實 adapter 正反例；不代替真機測試 |
| P24 Apple package resolution owner | [Apple package lock contract](toolchain/v1/apple-package-lock.md)、[case schema](toolchain/v1/schema/apple-package-lock-case.schema.json)、[cases](toolchain/v1/golden/apple-package-lock-cases.jsonl) | SwiftPM 根鎖 `Package.resolved`；XcodeGen／Xcode `examples/probe-app/project.yml`、`scripts/ci/xcode-resolve.sh` | 冷缓存严格解析、版本冲突和独立锁真实工具测试；不代替设备运行 |
| P25 BotEventLog／effects owner | [bot/v1/event-envelope.schema.json](bot/v1/event-envelope.schema.json)、[event golden](bot/v1/golden/event-envelope.json) | dsh-bot `events/envelope.cjs`、`journal/`；Swift `Sources/PhoneDSHBot/{Store,Journal,Gateway,Authz}` | `spec/bot/v1/tools/validate_vectors.py`；Swift `PhoneDSHBotTests` 隨 WP3/WP4 實作；不得與 P03 journal 混用 |
| P26 BotToolSurface／memory／wake／observability owner | [bot/v1/README.md](bot/v1/README.md)、`spec/bot/v1/{tool-catalog,card-payload,volatile-context,tool-effects,approval-patterns,memory-fact,memory-policy,memory-injection,memory-recall,routine,wake-routine,held-inbox-item,llm-ledger,model-purpose-policy,watchdog,fish-director,context-profiles,context-lint}.schema.json` 與 golden | dsh-bot `mcp/dshbotServer.cjs`、`cardPayloads.cjs`、`authz/`、`memory.cjs`、`wake.cjs`、`routines.cjs`、`ledger.cjs`、`llm/`、`watchdog/`、`prompt/assemble.cjs`、`eval/contextLint.cjs`；Swift `Sources/PhoneDSHBot/{MCP,Memory,Wake,Routines,Proactive,Providers,Ledger,Watchdog}`；TS `plugins/bot-runtime/` | `spec/bot/v1/tools/validate_vectors.py`；Swift/TS 各工作包測試；P1 卡片只登記 target，不進第一版工具面；macOS／Team／CloudAgent 不在手機工具面 |
| P27 BotRows／UserAction owner | `spec/bot/v1/{row,row-batch,row-projection,user-action,action-result}.schema.json` 與 golden | dsh-bot `dshProjection.cjs`、`transcriptWire.cjs`、`displayContract.js`；Swift `Sources/PhoneDSHBot/Rows`、SwiftUI `examples/probe-app/PhoneDSHProbe/Bot` | `spec/bot/v1/tools/validate_vectors.py`；Swift 行投影與 UI 測試隨 WP8/WP9 實作 |

登記表不宣稱窮盡。新增或發現未登記的公共邊界時，**先補一行**（權威、兩端、證據），再分派實作。

## 4. 路徑 → 契約觸發表

diff 觸及下列任一路徑，就必須逐 ID 聲明 `Protocol impact`：例如
`Protocol impact: P01; P09: none — 僅改 UI 註解`。裸 ID 表示有影響；每個 `ID: none — 理由`
只解釋該 ID 無行為影響，不能代替其他 ID。所有觸發 ID 都必須出現；理由中提到的 ID 不算聲明。
只有完全沒有觸發時，才接受整體 `Protocol impact: none — 理由`。
比較起點為 `git merge-base <base> HEAD`，再對工作區計算 diff（與三點比較的左端一致）；
base 分支單邊前進不算本分支改動。一個檔案可同時屬於多個 ID。glob 以倉庫根為起點。

| ID | 觸發路徑 |
| --- | --- |
| P01 | `spec/v1/{channel.md,README.md}`、`spec/v1/schema/{hello,exec-req,exec-ctl,lifecycle,fence,error,console,api-*}.schema.json`、`spec/v1/golden/frames/**`、`Sources/PhoneDSHWire/**`（除 `WAL.swift`）、`Sources/PhoneDSHLoopback/{ChannelServer,DefaultChannelHandling,WebSocket,LoopbackServer}.swift`、`Sources/PhoneDSH/PhoneDSHChannel.swift`、`plugins/channel/src/**`（除 `wal*`）、`shell/crates/pdsh-wire/**`、`shell/crates/pdsh-jni/src/{lib,bridge}.rs`、`android/core/src/main/kotlin/com/phonedsh/wire/**`、`android/dsh/src/main/kotlin/com/phonedsh/dsh/host/{HostHello,HostChannel,VfsFrames,VfsSink,BootId}.kt`、`android/engine/src/main/kotlin/com/phonedsh/engine/{FrameType,HelloFields,ChannelReopenLane,ObservedChannelHandler}.kt` 、`harmony/host-rust/src/ws.rs`、`harmony/host-rust/src/host.rs` |
| P02 | `spec/v1/wal.md`、`spec/v1/schema/{manifest,wal-replay}.schema.json`、`spec/v1/golden/wal/**`、`Sources/PhoneDSHWire/WAL.swift`、`Sources/PhoneDSHLog/**`、`plugins/channel/src/{wal,vfs-mutation}.ts`、`shell/crates/pdsh-wal/**`、`shell/crates/pdsh-jni/src/wal.rs`、`android/core/src/main/kotlin/com/phonedsh/log/**`、`android/core/src/main/kotlin/com/phonedsh/wire/{NativeWal,WalException}.kt`、`android/dsh/src/main/kotlin/com/phonedsh/dsh/host/{HostWal,WalUplink,HostLog}.kt`、`android/engine/src/main/kotlin/com/phonedsh/engine/BootOverlay*.kt` 、`harmony/host-rust/src/wal.rs`、`harmony/host-rust/src/overlay.rs` |
| P03 | `spec/v1/{exec,handoff,budgets}.md`、`spec/v1/schema/{handoff-*,perturbation}.schema.json`、`spec/v1/golden/perturbations/**`、`Sources/PhoneDSHController/**`、`Sources/PhoneDSH/{Handoff,Background}/**`、`Sources/PhoneDSH/{PhoneDSHLedger,PhoneDSHHost,PhoneDSHLifecycle,PhoneDSHInactivity,HostFault}.swift`、`Sources/PhoneDSHAgentCore/{ExecBridgeHosting,Delegation}.swift`、`plugins/{exec-bridge,tool-journal,lifecycle-gate,subprocess-xl}/src/**`、`android/controller/src/main/**`、`android/dsh/src/main/kotlin/com/phonedsh/dsh/{exec,journal,background}/**` 、`harmony/host-rust/src/ws.rs`、`harmony/host-rust/src/wal.rs` |
| P04 | `spec/v1/bridge.md`、`spec/v1/schema/bridge-message.schema.json`、`spec/v1/golden/bridge/**`、`Sources/PhoneDSHEngine/WebEngine*.swift`、`examples/probe-app/ProbeKit/MCPControlBridge.swift`、`plugins/phone-native-preview/src/**`、任何 `plugins/*/src/client/**` 中的 `postMessage`／`webkit.messageHandlers`、`android/engine/src/main/kotlin/com/phonedsh/engine/{WebViewEngine,WebViewKernel,NavigationPolicy,EngineCapabilities}.kt` 、`harmony/entry/src/main/ets/host/HostBridge.ets`、`harmony/web/engine.mjs`、`harmony/web/product-worker.mjs` |
| P05 | `spec/v1/{gateway-security,native-mcp}.md`、`spec/v1/gateway-official-web.md`、`spec/v1/schema/gateway-vector.schema.json`、`spec/v1/golden/{gateway,native-mcp}/**`、`spec/v1/tools/{native_mcp_check,test_native_mcp_check}.py`、`Sources/PhoneDSHGateway/**`、`Sources/PhoneDSHLoopback/{HTTPTransport,HTTPEgressFailure,StreamingForward,Loopback,Support,NativeMCP}.swift`、`Sources/PhoneDSHAgentCore/{Credentials,HTTPSupport,ProviderError}.swift`、`Sources/PhoneDSHADB/**`、`Sources/PhoneDSHBLE/DeviceMCPServer.swift`、`plugins/llm-bridge/src/**`、`plugins/phone-mcp/src/{manager,schema,protocol}.ts`、`plugins/worker-entry/src/model-route.ts`、`android/net/src/main/**` 、`harmony/entry/src/main/ets/host/HostHttpProxy.ets`、`harmony/entry/src/main/ets/host/HostModelAlias.ets`、`harmony/host-rust/src/http.rs` |
| P06 | `plugins/lifecycle-gate/src/device-{scope,guard}.ts`、`spec/device/v1/task-delegation.md`、`spec/device/v1/schema/task.schema.json`、`spec/device/v1/golden/task-cases.jsonl`、`spec/host/v1/**`（除 `device-*`）、`Sources/PhoneDSHAgentCore/{AgentHarness.swift,DSH/**}`、`Sources/PhoneDSH/PhoneDSHEvents.swift`、`android/core/src/main/kotlin/com/phonedsh/{agentcore,hostevents}/**`、`android/dsh/src/main/kotlin/com/phonedsh/dsh/turn/**` 、`harmony/entry/src/main/ets/host/TranscriptProjection.ets`、`harmony/entry/src/main/ets/host/HostService.ets` |
| P07 | `spec/device/v1/**`、`plugins/lifecycle-gate/src/device-{scope,guard}.ts`、`Sources/PhoneDSHDeviceTasks/**`、`Sources/PhoneDSHLAN/**`、`examples/lan-mcp-device/**`、`Sources/PhoneDSHBLE/**`、`firmware/**`、`spec/host/v1/schema/device-*`、`spec/host/v1/golden/device-*`、`docs/design/device-*.md`、`android/domain/src/main/kotlin/com/phonedsh/domain/{device,connector}/**`、`examples/probe-app/ProbeKit/Devices/**` |
| P08 | `spec/platform/**`、`android/platform*/src/main/**`、`Sources/PhoneDSHController/Signals/**`、`Sources/PhoneDSH/Background/**`、`examples/probe-app/ProbeKit/PhoneAudioSessionLease.swift`、`examples/probe-app/ProbeKit/Capabilities/PhoneMediaTools.swift`、`examples/probe-app/PhoneDSHProbe/{BackgroundKeepAlive,ComposerVoiceInput}.swift` 、`harmony/entry/src/main/ets/entryability/EntryAbility.ets` |
| P09 | `spec/ui/v1/**`、`scripts/ci/check.sh`、`scripts/ci/test_p0_completeness.py`、`spec/v1/trajectory.md`、`spec/v1/schema/{trajectory,ui-state-sequence}.schema.json`、`spec/v1/golden/trajectory/**`、`examples/probe-app/PhoneDSHProbe/**`、`android/lib/src/main/**` 、`harmony/entry/src/main/ets/ui/**`、`harmony/entry/src/main/ets/model/Contracts.ets` |
| P10 | `plugins/workflow-worker/src/**`、`plugins/types/dsh-workflow-*.d.ts` |
| P11 | `plugins/wasi-toolbox/src/{vfs-*,sab-client-worker,message-endpoint,worker-scope,tool-worker-runtime,stdin-delivery,types}.ts` |
| P12 | `shell/include/**`、`shell/crates/{pdsh-ffi,pdsh-jni,pdsh-core}/**`、`shell/build-apple.sh`、`Sources/PhoneDSHShell/**`、`Package.swift`、`spec/platform/android-module-map.json`、`spec/platform/schema/android-module-map.schema.json`、`spec/platform/schema/android-module-map-vector.schema.json`、`spec/platform/golden/android-module-map-cases.jsonl`、`android/README.md`、`android/tools/structure_check.py`、`android/tools/test_structure_check.py`、`android/shell/src/main/**`、`android/core/src/main/kotlin/com/phonedsh/wire/Native*.kt` 、`harmony/host-rust/include/pdsh_host.h`、`harmony/entry/src/main/cpp/napi_init.cpp`、`harmony/entry/src/main/cpp/types/libpdshhost/index.d.ts` |
| P13 | `plugins/{phone-shell,phone-feature-admin,phone-mcp,phone-directory-import,phone-model-config}/src/{contract*,protocol,types,remote,service,index}.ts`、`plugins/surface-phone/src/management-remote.ts`、`Sources/PhoneDSH/PhoneDSHWorkspaceImportSink.swift` 、`harmony/entry/src/main/ets/host/HostService.ets` |
| P14 | `Sources/PhoneDSH/ChannelDSHTransport.swift`、`Sources/PhoneDSHAgentCore/DSH/DSHRemoteTransport.swift`、`plugins/worker-entry/src/mux-*.ts`、`android/dsh/src/main/kotlin/com/phonedsh/dsh/turn/DshTurnClient.kt` 、`harmony/web/engine.mjs` |
| P15 | `Sources/PhoneDSH/{PhoneDSHWorkerCommand,PhoneDSHRecovery,PhoneDSHDescendantDrain}.swift`、`plugins/surface-phone/src/*-controller.js` |
| P16 | `Sources/PhoneDSH/PhoneDSH.swift`、`Sources/PhoneDSHEngine/{WebEngineConfiguration,WebEngineScripts}.swift`、`examples/probe-app/PhoneDSHProbe/ChatModel.swift`（`PDSH_*` env）、`plugins/profile/phone.worker.cordis.patch.yml`、`android/engine/src/main/kotlin/com/phonedsh/engine/WorkerEnvironment.kt`、`plugins/worker-entry/{www/boot.js,src/web-boot.ts,src/entry.ts}` 、`harmony/host-rust/src/host.rs`、`harmony/web/product-worker.mjs` |
| P17 | `plugins/exec-bridge/src/{client,transport}.ts`、`Sources/PhoneDSHLoopback/LoopbackServer.swift`、`Sources/PhoneDSHAgentCore/ExecBridgeHosting.swift`、`Sources/PhoneDSHGateway/ModelGateway.swift`、`Sources/PhoneDSHShell/PDSHShellTypes.swift`、`Sources/PhoneDSH{SSH,ADB}/**` |
| P18 | `plugins/worker-entry/src/capabilities.ts`、`plugins/shell-ext/src/contract.ts`、`plugins/phone-mcp/src/schema.ts`、`plugins/phone-model-config/src/model-config.ts`、`Sources/PhoneDSH/Phone*Settings.swift`、`Sources/PhoneDSH{SSH,ADB}/**`、`Sources/PhoneDSHBLE/LinkToolJournal.swift`、`Sources/PhoneDSHBLE/BLEIdentity.swift`、`spec/device/v1/legacy-identity-preferences.md`、`Sources/PhoneDSHDeviceTasks/DeviceTaskJournal.swift`、`Sources/PhoneDSHLog/MaterializedInvariant.swift`、`Sources/PhoneDSHScenario/ScenarioBudgets.swift` 、`harmony/entry/src/main/ets/host/HostPersistence.ets`、`harmony/entry/src/main/ets/model/ProviderProfiles.ets` |
| P19 | `shell/crates/pdsh-phone/**`、`examples/probe-app/ProbeKit/Capabilities/PhoneTool*.swift`、`android/dsh/src/main/kotlin/com/phonedsh/dsh/host/PhoneInfoTool.kt` |
| P20 | `plugins/scripts/pack-image.mjs`、`plugins/dsh-pin.json`、`plugins/bundle/**`、`Sources/PhoneDSHLoopback/LoopbackServer.swift`、`android/engine/src/main/kotlin/com/phonedsh/engine/{WorkerAssets,*WorkerAssetSource}.kt` 、`harmony/tools/stage-runtime.mjs`、`harmony/host-rust/src/bundle.rs` |
| P21 | `spec/v1/render-media-v1.md`、`spec/v1/office-ir-v1.json`、`Sources/PhoneDSHEngine/{PageSchemeHandler,PageSurface}.swift`、`examples/probe-app/ProbeKit/Office/**` |
| P22 | `spec/v1/schema/{scenario-*,perturbation,upstream-script}.schema.json`、`spec/v1/golden/upstream/**`、`scripts/ci/scenarios/**`、`Sources/PhoneDSH{Scenario,Harness}/**`、`android/testkit/**` |
| P23 | `spec/toolchain/v1/{sdk-manager.md,schema/sdk-manager-listing.schema.json,golden/sdk-manager-listing.jsonl}`、`android/tools/bootstrap-android-toolchain.sh`、`android/tools/test_bootstrap_android_toolchain.py` |
| P24 | `spec/toolchain/v1/{apple-package-lock.md,schema/apple-package-lock-case.schema.json,golden/apple-package-lock-cases.jsonl}`、`Package.resolved`、`examples/probe-app/{project.yml,PhoneDSHProbe.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved}`、`scripts/ci/xcode-resolve.sh`、`.gitignore`、`examples/probe-app/.gitignore` |
| P25 | `spec/bot/v1/event-envelope.schema.json`、`spec/bot/v1/golden/event-envelope.json`、`spec/bot/v1/dshbot-pin.json`、`spec/bot/v1/export-manifest.json`、`spec/tools/bot/**`、`Sources/PhoneDSHBot/**` |
| P26 | `spec/bot/v1/README.md`、`spec/bot/v1/{tool-catalog,card-payload,volatile-context,tool-effects,approval-patterns,memory-fact,memory-policy,memory-injection,memory-recall,routine,wake-routine,held-inbox-item,llm-ledger,model-purpose-policy,watchdog,fish-director,context-profiles,context-lint}.schema.json`、`spec/bot/v1/golden/{tool-catalog,card-payload,card-payload.phone,volatile-context,tool-effects,approval-patterns,memory-fact,memory-policy,memory-injection,memory-recall,routine,wake-routine,held-inbox,llm-ledger,model-purpose-policy,watchdog,fish-director,context-profiles,context-lint}.json`、`spec/bot/v1/dshbot-pin.json`、`spec/bot/v1/export-manifest.json`、`spec/tools/bot/**`、`Sources/PhoneDSHBot/**`、`plugins/{bot-runtime,profile}/**` |
| P27 | `spec/bot/v1/{row,row-batch,row-projection,user-action,action-result}.schema.json`、`spec/bot/v1/golden/{row-projection,row-protocol}.json`、`spec/bot/v1/dshbot-pin.json`、`spec/bot/v1/export-manifest.json`、`spec/tools/bot/**`、`Sources/PhoneDSHBot/**`、`examples/probe-app/PhoneDSHProbe/**` |

此表由 `registry_check.py` 校驗與 registry 的一致性；`protocol_impact.py` 可在本地校驗 diff 與描述（見 §9）。路徑改名或新增實作檔時，同一變更更新此表，再執行 `python3 spec/tools/registry_build.py --write`。

## 5. 相容性規則

### 5.1 通用規則（所有邊界）

以下規則借自 Kubernetes API conventions 與 Protobuf 實踐（來源見[研究紀錄](../docs/research/protocol-baseline-2026-11-03.md)），
適用於每個邊界，除非該邊界的 owning contract 明文另訂：

1. **同一語義只有一種表達。** 不得新增第二個欄位、第二種 envelope、第二個錯誤碼或別名來表達已存在的語義。
   現有違例必須登記為 GAP，不得擴散。
2. **新增欄位必須可選，且定義缺省時的行為。** 舊 producer 不會送它；舊 consumer 必須能忽略它（若該邊界
   允許未知欄位）或在協商後才送（若不允許）。
3. **兩端都讀的訊息不能收緊也不能放寬。** 讓原本合法的輸入變非法，或原本非法的輸入變合法，都是 breaking。
4. **新增 enum／kind／錯誤碼不是自動相容。** 若 owning contract 沒寫明消費者遇到未知值的處理，就不能直接加值；
   先補上未知值規則，或走新版本。
5. **刪除與改名是 breaking。** 先標 `deprecated` 並登記移除條件；欄位編號、frame type、錯誤碼、方法名永不重用。
6. **持久化資料永遠可讀。** 新代碼必須能讀登記的舊 golden／舊盤資料；降級／回滾路徑要說明。

### 5.2 邊界專屬規則

| 邊界 | 已有規則；變更時必須保持的差別 |
| --- | --- |
| P01 `proto: 1` | HELLO 協商版本與能力，缺少能力不可使用；不同 proto 拒絕。新增 frame type、flag、required member 或改既有語義需新 major（v1 README §2）。decoder 不可要求 canonical 排版；encoder 仍遵循 schema 與 canonical JSON |
| P04 `bridge 1` target | schema 關閉未知欄位，`requestId`／method／terminal 規則由 bridge.md 定義。不得套用 P06 的忽略未知欄位策略；target 的 `v:1` 與現行 preview 的 `v:1` 不是同一格式 |
| P06／P07 host contract 1 | 未知 member／event／capability 依 host README §2；事件種類可加，但 required member、移除／改名／改語義需 major。未知 durable event 仍消耗 cursor；best-effort 沒有 durable seq |
| P02、P18 持久化 | 版本、checksum、順序、原子提交與恢復依 wal.md；設定檔依其權威源檔的版本號。不能只更新 Swift Codable 型別 |
| P10–P17、P19、P20 code contracts | 同次建置配對不代表舊 bundle／舊 native artifact 能消費新格式。兩端不能原子更新時，先設計版本辨識或 adapter；沒有現成 negotiation 就如實記錄，不偷偷加自訂版本欄位 |

每次變更至少回答四格：old producer→new consumer、new producer→old consumer、new→new、
舊持久化資料→新代碼／回滾。任何不支援的組合都要寫出拒絕方式、部署順序與回滾限制。
未知欄位／方法、缺省值、null、整數上限、浮點、字元編碼、max payload 都屬於相容性。

## 6. 必守語義

1. **序號有各自生命週期**：channel `seq` 每連線每方向；VFS `mseq` 持久；journal `jseq` 每 session；
   harness durable event `seq` 是 cursor，容許 gap。不可互換或用差值推算遺失數。
2. **確認要對應承諾**：WAL L1 承諾與 L2 epoch durability 分開；HTTP／bridge／MQTT 的接受回覆不是外部動作
   已完成。設備執行要對應 command 的 applied／failed receipt。
3. **取消與超時不證明副作用沒有發生**：保留同一操作的 idempotency／fence／結果查詢語義，不能用新 ID 盲重送。
   `SideEffectLedger` 是 exec／MCP replay 機制，不能推論成任意遠端 API 的 exactly-once。
4. **恢復要重新確認權威**：HELLO、incarnation、fence generation、lease、WAL／journal watermark 各有 owning rule。
   舊 Worker 的 ready／ACK 不可當成新 Worker 的授權。
5. **有界與隔離**：保留 payload／buffer／queue／timeout／budget 上限與可觀察錯誤；token 留在 host 的既定
   credential 機制；origin、main-frame、workspace path、capability 檢查不得為了方便測試而放寬。
6. **數值不可默默失真**：binary u64、JSON number、Swift Int／Double、JS number／bigint、Kotlin Long 的有效域不同。
   使用 owning codec；不可經 `String`／`Int` 任意轉換（見 GAP-02）。

## 7. 已知差異：維護債，不是實作許可

以下保留 revision 2 的原始 source review，不是 runtime 實驗；後續工具進度見 §9，本輪不關閉任何 GAP（GAP-12／GAP-13 為本次新登記的 iOS 實作缺口，見下）。本基線沒有修改任何訊息格式，也沒有宣稱它們已修好。
修正時附 contract delta 與 regression；**不得為了消除差異把規範改成寬鬆的實作現狀**。

**本次凍結（2026-11-04）。** CCR-1（wal.md §6.2／§5.1 的 `superseded` 第四判定）與 CCR-2（drain 等待 outstanding VFS_RESYNC、啟動 mseq-1 重建、Failed→Recovering 順序）已由變更單
[PC-20261104-wal-superseded-drain](../docs/protocol-changes/PC-20261104-wal-superseded-drain.md) 以 `status: frozen` 凍結；`contract_revision` = `5b573cb2`。
第 2 輪審查把 settlement 收緊為保守語義：superseded 記錄只有在 cover 已套用、且 cover 的 mseq ≤ manifest 水位時才計入連續水位；replay vectors 以可選 `watermark_steps` 斷言這條不變式。
GAP-12／GAP-13 是同一批實作要修的 iOS 缺口，不是合約變更。

| ID／邊界 | 觀測 | 關閉條件 |
| --- | --- | --- |
| GAP-01／P04 | bridge.md §11–12 的 unified envelope 為 `target`；preview 實際為 `{v,id,sessionId,path}`／`{id,ok,code,message}` | caller、receiver、shim、錯誤／取消／timeout、舊 bundle 策略一起遷移，兩端 runtime conformance 通過後改為 `implemented` |
| GAP-02／P01 | [hello schema](v1/schema/hello.schema.json) 允許完整 u64；TS `host-hello.ts` 要求 safe integer；Kotlin `HostHello.kt` 用 signed Long（Rust codec 支援完整 u64，截斷發生在 JNI→Kotlin） | 加 2^53 與 u64 邊界共同向量，選定有效域與版本方案，三端讀同一批資料 |
| GAP-03／P01 | Swift `HelloPayload.validate` 與 Python oracle 要求 `next_mseq == acked_mseq + 1`；TS `parseHostHello` 只要求 `next > acked`；Kotlin 生產端自檢同樣寬鬆 | 共同 negative HELLO 向量；依 channel.md §4.1、wal.md §7.2 決定，修正寬鬆端 |
| GAP-04／P01 | Swift 拒絕重複或不合法 capability、拒絕帶 `last_mseq` 的 host HELLO；TS 不檢查這兩項；Python oracle 比 schema pattern 更嚴 | 加入共用 negative fixtures，對齊 schema、oracle、三端 parser |
| GAP-05／P04 | preview 超時：TS 頁面側錯誤碼 `native-preview-timeout`，Swift 為 `preview-timeout`——同一語義兩個碼 | 在 owning contract 選定一個碼，另一個標 `deprecated` |
| GAP-06／P17 | `spec/exec-bridge-v1` 被 `ModelGateway.swift`、`PDSHShellTypes.swift` 等引用，倉內不存在 | 補齊規範或改引用到實際權威；補齊前該邊界只能做經變更單批准的修改 |
| GAP-07／P04 | `pdshOpenModelSettings` 有兩個 TS 發送端，倉內無原生接收端 | 登記接收端所在位置，或標為 `legacy` 並移除 |
| GAP-08／證據 | 沒有 gate 跑 Rust `cargo test`（pdsh-wire／pdsh-wal golden 測試從不在 CI 執行）；bridge golden 無 runtime 消費者；gateway 與 host golden 只有 Kotlin 消費，Swift 不讀 | 每個規範化邊界至少兩端真實 decoder 讀同一批 golden |
| GAP-09／狀態 | 狀態標記各自為政（見 §2 對照表）；v1 README 把含 28 個 `[NEW]` 的 bridge.md 標為 landed；budgets.md 與 platform whitelist 引用 `draft` 的 render-media-v1.md | 狀態對齊 §2 詞彙；normative 不再依賴 draft |
| GAP-10／P13 | 至少 6 個 Remote service 共用 `phone` namespace，沒有方法名登記 | 建立方法清單，新增方法前查重 |
| GAP-11／P14、P16 | 代碼引用 D21–D24，v1 README 決策表只到 D20 | 補入決策表或移到對應 code contract 的註解中並在此登記 |
| GAP-12／P02（iOS） | iOS `WorkspaceLog` 定義 `defaultEpochIntervalSeconds = 45` 與 30–60 s 邊界，但沒有任何 timer 調用 `closeEpoch`；[wal.md](v1/wal.md) §5.2 的週期 close 在 iOS 缺席（Android 在 PR14 已有 lane）。由 [PC-20261104-wal-superseded-drain](../docs/protocol-changes/PC-20261104-wal-superseded-drain.md) 的 iOS implementer 修 | iOS 在 `Running` 且無 held resync 時按 30–60 s 週期 close；regression 在 60 s 視窗內斷言 `closeEpoch` 被調用一次，held 時不 close。runtime 證據後才關閉 |
| GAP-13／P02（iOS） | iOS `WorkspaceLogService.pendingResyncPaths()` 沒有生產調用者；recovery 留下的 resync 不會在 HELLO 後重新請求，違反 wal.md §10 step 4 與 channel.md §9 item 6。由同一變更單的 iOS implementer 修 | `pendingResyncPaths()` 接到 HELLO 後路徑；regression 斷言每個 pending path 恰好一個帶 `mseq` 的 VFS_RESYNC，settle 後不重發。runtime 證據後才關閉 |
| GAP-14／HarmonyOS | 新平台为 partial；尚未完成全量页面、模型流、取消、恢复及平台能力验收。边界登记与迁移见 [PC-20261104-harmony-host](../docs/protocol-changes/PC-20261104-harmony-host.md) | 真实 HAP 的每个受影响端通过有效/非法、断开/取消/恢复场景；平台限制单独登记，不由编译或模拟器替代真机/掉电证据 |
| GAP-15／P07（已修復 `c9d95b31`） | Swift Foundation、cJSON 與 Python 預設對重複 object key 的取值不一致 | task contract 已凍結全層拒絕；Swift、Python 與 C 讀同一組 raw JSON 正反向量，設備傳輸及恢復測試已重跑。任務 profile 的完整應用驗收仍另行開放 |
| GAP-16／P07（iOS BLE 任務） | 真機負向測試中，未加密、未配對的 Mac 測試外設可成功協商 task tools；iOS 不能把外設聲明或訂閱成功當作 bond 證據；獨立 challenge 簽名亦不能保護其後任務／回執免遭中間人竄改 | iOS 拒絕全部 BLE task grant，參考固件普通 Link 入口拒絕新明文任務；凍結可驗證的設備身分、雙向認證及完整性保護的會話、配對方案、相容／復原決策和正反向 fixture，實作手機與固件兩端，並用真機證明偽造／未配對對端被拒、已配對對端成功後才可啟用。既有回執未被此入口限制鑑定 |
| GAP-17／P07（LAN 參考發布） | `examples/lan-mcp-device/server.py` 的 `dns-sd -R` 由系統選擇 SRV target，未驗證其符合 LAN discovery 名稱規則及與設定的 TLS hostname 一致；decoder 向量不能證明實際發佈值 | 經契約 owner 確定並實作有界、可觀察的發佈驗證或一致性策略；真實 DNS-SD 發佈／解析、名稱不符與失敗路徑有 runtime 證據後才關閉 |
| GAP-18／P07、P13（LAN A-label） | LAN 三端按 ASCII DNS 标签形状接受部分 A-label；Node 运行的 MCP URL parser 与 macOS／iOS Simulator WKWebView 对 `xn--a.example` 的接受结果不同，产品内 iOS Worker 行为未验证。仅已有正例通过不证明所有候选可消费 | 由 [CCR](../docs/protocol-changes/PC-20261107-lan-idna-ccr.md) 冻结跨端 IDNA/A-label 验证与兼容策略；Swift、Python、Android 和真实 Worker parser 共同运行正反向向量后关闭 |
| GAP-19／P09（条件编译抽取） | 页面抽取器同时读取 Swift `#if` 的活动与非活动分支；默认关闭的设备任务 UI 仍进入 parity 结果，构建条件与实际产物无法对照 | 按 [CCR](../docs/protocol-changes/PC-20261107-ui-build-profile-ccr.md) 冻结可复核 profile、保留旧数据及正反向 fixture；真实编译条件、提取器 mutation 和跨平台 parity 均通过后关闭 |
| GAP-20／P07、P08（Android GATT） | Android 普通 Link 目标通道要求区分每次写回调，但 API 26–35 的同连接同特征回调没有写入 token；bond 状态也不能证明当前链路加密。尚无已接入的 Android GATT adapter | 按 [CCR](../docs/protocol-changes/PC-20261107-android-gatt-ccr.md) 冻结可验证的回调归属、权限及安全语义；实际 Android adapter 与通道共同覆盖陈旧/重复回调、失败和断线，并以真机证据验证后才关闭 |
| GAP-21／P09（UI 语义抽取） | 结构抽取以语法启发式为主，可能遗漏私有 editor 的安全控件，把调用 helper 的副作用标为只读，或漏掉 disabled guard；仅记录页面名称及语法锚点不能证明安全 UI parity | 由 P09 owner 冻结可执行的 helper／私有子页／授权与 busy guard 语义，两端用实际状态和失败路径验证；不得凭页面清单或 source inventory 通过即关闭 |
| GAP-22／P09（队列动作结果） | iOS 与 Android 对队列动作的成功回执、读回失败和 not-found 提示不一致；异步结果仅按 session ID 检查，静态代码审计发现切换后返回同一 ID 的旧结果可能污染当前会话 | 按 [CCR](../docs/protocol-changes/PC-20261107-queue-action-ccr.md) 核对上游语义并冻结正反 fixture 与会话代数；两端真实状态机、页面提示和失败／切换路径通过后关闭。未完成前不得把任一端现状当作共同契约 |
| GAP-23／P06、P07（任务 JSON 深度） | 合法任务的未知值深度很大时，Swift、Python 和 C 的实际解析深度不同；任务契约尚未规定共同的深度或恢复策略 | 按 [CCR](../docs/protocol-changes/PC-20261107-task-json-depth-ccr.md) 冻结有依据的跨端限制及旧记录兼容，再用三端真实解码器、边界向量和设备资源证据验证；数字／Unicode 修复不关闭本项 |
| GAP-24／P07、P18（任务日志路径） | 父记录读取先检查路径再重新打开；锁、读取与部分写入仍分别解析路径，并发替换可造成检查对象与实际对象不一致。现有意图子目录局部使用 descriptor 不证明整个日志安全 | 按 [CCR](../docs/protocol-changes/PC-20261107-journal-path-ccr.md) 冻结目录、锁、文件身份及崩溃兼容规则，用真实读写与确定性竞态测试验证；不得凭 advisory lock 或单次 no-follow 读取关闭 |
| GAP-25／P22（场景 mock 关联） | 真实 Worker 的辅助标题请求和主回合请求共用 mock 响应序号；标题请求可消费预期给工具的回复，delivery 检查又把辅助响应与主回合 usage 混算 | 按 [CCR](../docs/protocol-changes/PC-20261107-worker-scenario-ccr.md) 冻结请求分类、重试和消费证据，覆盖请求重排和真实工具执行；不得简单扣减响应数或放宽文件断言 |
| GAP-26／P16、P22（Worker 启动诊断） | 带真实 Worker 的预算中止场景记录到不支持 PTY 的 terminal mount 异常和 browser connection pending 错误；`no_console_error` 正确看到这些事件 | 按同一 CCR 明确可见能力与启动行为，保留不支持能力 fail-loud、浏览器 bundle 和真实诊断；不得过滤日志、隐藏 preset 或放宽错误断言 |
| GAP-27／P09（动态页面标题） | 页面契约的 `title:null` 同时表示无标题和动态标题，Android checker 对 null 不比较；既有 `dynamic-both` 仅比较表达式存在，不验证状态与文案 | 按 [CCR](../docs/protocol-changes/PC-20261107-dynamic-page-title-ccr.md) 冻结无标题／动态表达式的可区分语义及两端验证；不得仅把标题改为 null 或凭动态表达式存在称通过 |
| GAP-28／P07、P09、P18（旧身份偏好，partial） | [保全契约](device/v1/legacy-identity-preferences.md)已冻结；旧标签不是可认证的设备身份。可见值与本地确认顺序现由真实隔离 UserDefaults、受控重入和模拟器页面测试覆盖 | [确认变更单](../docs/protocol-changes/PC-20261107-identity-observable-confirmation.md)仍不证明隐藏域、跨进程竞争、落盘恢复、真实设备或密钥绑定；不得据此开启设备任务或认证历史身份 |
| GAP-29／P07、P09（iOS 标准 GATT 授权，partial） | macOS 上真实 `BLEDeviceStore` 的同步 Observation 回调曾复现较晚撤权被外层授权覆盖；连接、pending read 和旧 Link 操作也有本地生命周期竞态 | [v2 契约](../docs/protocol-changes/PC-20261107-standard-gatt-grant-order.md)已冻结；真实 store 的模拟物理端点测试覆盖共享场景、撤权和隔离，不能证明 CoreBluetooth 回调归属或真实空口行为。仍需 iPhone 与实现标准服务的受控外设验证读取、取消、通知、断连和重连；不能据本地测试关闭本 GAP 或 GAP-16 |
| GAP-30／P07、P09（iOS 蓝牙全局状态重入，partial） | 全局 `status` 文案的意图顺序已冻结并由真实 store 的模拟回调与同步 Observation 测试覆盖；scan／stop／初始化重入已按 [扫描意图变更单](../docs/protocol-changes/PC-20261107-ble-scan-reentry-ccr.md)（`ble-link.md@scan-intent-v1`）冻结并修复，原四个诊断已转为真实 store 回归，并有 14 个共享用例与 15 个语义变异由同一比较器拒绝；这些仍只是模拟物理边界，不是 OS／设备证据 | 保留[状态变更单](../docs/protocol-changes/PC-20261107-ble-status-order.md)与扫描意图回归；以真实 CoreBluetooth 设备验证 scan／stop 提交顺序、权限提示、断电及其他状态驱动副作用后才可关闭 |
| GAP-31／P07、P09（iOS Link 发现归属，partial） | 服务变化的[保守失效](../docs/protocol-changes/PC-20261107-gatt-service-change.md)、[发现对象归属](../docs/protocol-changes/PC-20261107-gatt-discovery-ownership.md)和[超时 first-winner](../docs/protocol-changes/PC-20261107-discovery-deadline-order.md)已有真实 store 与模拟物理端点测试；CoreBluetooth 没有应用请求 token | 以受控真实外设验证多实例、迟到回调、服务变化与断连重连及 OS 行为；不能把本地模拟视为真机证据或据此启用任务 |
| GAP-32／P09（Android 页面 parity，owner android-parity；仅记录） | `phone-p0-conformance` 的 P09 页面结构门在 main `9b3b31e7` 已失败，与 #59 无关：该提交先在 stale 页面 provenance（如 `archived-sessions` 的 `SettingsPage.swift:331`）处 FAIL；在 #59 刷新 provenance 后的 `a379f2ba` 上，`python3 -B spec/ui/v1/tools/page_structure_check.py --root .` 报 41 处差异，其中 38 处属既有页面：`android-adb-settings`、`ssh-settings`（无 Android 页面）、`settings` 的 SSH／ADB 行、`archived-sessions`、`files`、`licenses`、`model-provider-settings`、`native-configuration`、`native-plugin-inventory`、`native-workbench`、`permission-defaults`；另 3 处（`mcp-settings` 的“局域网设备”区与扫描动作、`settings` 的“MCP 与局域网设备”行）由 #59 的 LAN 设备页引入，不属本项。CI 的 `--baseline spec/ui/v1/pages/_baseline.json` 棘轮在该提交报 28 处基线外新增差异 | 由 android-parity owner 补齐 Android 页面或经 P09 owner 按 §3 修订页面契约后，用同一检查器零差异重跑；不得增加 whitelist、删页面契约或放宽检查器来关闭 |
| GAP-33／P09（PR #64 Android 页面 parity，owner android-parity；仅记录） | 在 PR #64 合入后的 `dfa32fc6` 上重新生成页面契约并刷新 provenance 后，`python3 -B spec/ui/v1/tools/page_structure_check.py --root .` 报 48 处差异：13 处为 `_baseline.json` 既有、24 处为 GAP-32 既有，另 11 处由 #64 的 UI 重做引入，故 `--baseline spec/ui/v1/pages/_baseline.json` 的棘轮报 35 处基线外新增差异。这 11 处是：`connectors` 缺少 Android 对应页（1）；`settings` 的“我的”页新结构缺少 Android 的“Phone DSH”“设置”两个 section 判据行及“Phone DSH”“定时任务”“设备连接”“设置”四个动作（6）；`home-drawer` 删除底部设置栏而 Android 仍渲染“设置”（1）；`daily-brief` 删除“取消”而 Android 仍渲染（1）；`native-automation` 新增“完成”而 Android 未实现（1）；`session-artifacts` 删除“完成”而 Android 仍渲染（1）。`HomeTabBar.swift` 不是 `*Page`，现有检查器不要求独立契约，故不产生单独检查项。 | 由 android-parity owner 补齐 `ConnectorsPage` 及上述 Android 行／动作，或经 P09 owner 按 §3 修订页面契约后，用同一检查器零差异重跑；不得增加 whitelist、删页面契约、放宽检查器或增长 `_baseline.json` |

只有修正來源、相關端測試及必要的 integration 證據齊備，才在此記錄關閉與修復 commit。

## 8. 驗證矩陣：沿用現有工具

| 實際變動 | 命令與證據範圍 |
| --- | --- |
| spec／schema／golden／本頁 | `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`：規範與 fixtures 一致，本頁與 AGENTS 的連結存在；**不是 runtime conformance** |
| P01／P02 codec | `swift test --filter PhoneDSHWireTests`（持久化加 `PhoneDSHLogTests`）；TS 同一 golden 測試；`bash scripts/ci/check.sh --only phone-rust-tests`（cargo 缺失為 SKIP／INCOMPLETE，記錄實際結果）；Android `phone-android-tests` |
| Worker／TS | `cd plugins && npm run typecheck && npm test`；`phone-compat`。依賴未安裝是 `NOT_RUN`，不是通過 |
| host／controller／gateway／harness | 對應 Swift test target 與回歸；host path 跑 `bash scripts/ci/smoke.sh`。需要 Worker bundle／image／模型的項目分別記錄是否真的執行 |
| Android／native ABI | `phone-android-structure`、`phone-android-tests`；影響產物時加 `phone-android-release`。JVM 測試不等於 WebView／真機 |
| 公倉交付 | hygiene／license／no-dsh-patch 與受影響 gates；完整清單以 `bash scripts/ci/check.sh --list` 為準 |

`phone-cross-tree` 檢查本頁與 AGENTS 的本地連結、CLAUDE import、registry 與 §3／§4 逐字投影及路徑／glob、schema breaking diff；不是 runtime conformance。
結果用 `PASS／FAIL／SKIP／INCOMPLETE` 原樣記錄；沒跑記 `NOT_RUN`，沒有測量證據記 `NOT_VERIFIED`。

## 9. 機器強制路線圖與進度

文件只能指引；能擋住「各改各的」的是 CI。下列項目按收益排序，實作前各自走變更流程：

1. **已完成：機器可讀登記表**。`registry.json` 逐條保留 §3／§4 的來源與結構化投影；`registry_build.py --write` 生成 JSON，`--check` 要求逐字節可重現；`registry_check.py` 校驗 schema、ID、來源、觸發條件及路徑，兩者在 `phone-cross-tree` 執行。
2. **已完成本地工具：觸發檢查**。`protocol_impact.py --base <ref> --body-file <path>` 校驗 §4 的所有觸發 ID；支援 `P01; P09: none — 理由` 逐項聲明，只有零觸發才接受整體 `none`。尚未接入 hosted workflow；理由真實性仍由審查者判斷。
3. **partial：兩端讀同一批 golden**。已接 `phone-rust-tests` 跑 pdsh-wire／pdsh-wal；Swift 讀 gateway／host golden 與正反例命名仍未實作。GAP-08 不因 Rust gate 通過而關閉。
4. **已完成：schema breaking diff**。`schema_diff.py --base <ref>` 對 schema 做保守結構比較，在 `phone-cross-tree` 執行；breaking 需本次變更單的 `breaking: true`、contracts、匹配 merge-base（變更單 base 也用同一規則解析）、frozen 狀態及版本決定。
5. **未做：CODEOWNERS** 與 code owner review；本輪明確不新增，也不調整 GitHub 設定。
6. **已完成：CLAUDE.md 改為 `@AGENTS.md` import**。普通檔首行為 `@AGENTS.md`，不另寫規則；`cross_check.py` 拒絕 symlink、缺失檔與錯誤 import。Windows／Claude 實際載入尚未驗證。

[研究依據](../docs/research/protocol-baseline-2026-11-03.md)說明借鑑來源與不採用的做法；它是研究紀錄，不覆寫本頁。
