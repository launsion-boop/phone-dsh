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
| P01 channel／wire owner | [v1/channel.md](v1/channel.md)、[v1/schema](v1/schema)、[golden/frames](v1/golden/frames) | Swift [PhoneDSHWire](../Sources/PhoneDSHWire/)、[ChannelServer](../Sources/PhoneDSHLoopback/ChannelServer.swift)、[PhoneDSHChannel](../Sources/PhoneDSH/PhoneDSHChannel.swift)；TS [channel](../plugins/channel/src/)；Rust [pdsh-wire](../shell/crates/pdsh-wire/) 經 [pdsh-jni](../shell/crates/pdsh-jni/) 供 Android；Kotlin [core/wire](../android/core/src/main/kotlin/com/phonedsh/wire/)（JNI 殼）、[dsh/host](../android/dsh/src/main/kotlin/com/phonedsh/dsh/host/) 的 HostHello／HostChannel／VfsFrames | [Swift](../Tests/PhoneDSHWireTests/GoldenFrameTests.swift)、[TS](../plugins/channel/src/golden-frames.test.ts)、[Kotlin](../android/core/src/test/kotlin/com/phonedsh/wire/WireGoldenFramesTest.kt)、[Rust](../shell/crates/pdsh-wire/tests/golden_frames.rs)（`phone-rust-tests`；GAP-08 的其餘證據仍開放） |
| P02 VFS／WAL owner | [v1/wal.md](v1/wal.md)、[manifest schema](v1/schema/manifest.schema.json)、[golden/wal](v1/golden/wal) | Swift [PhoneDSHLog](../Sources/PhoneDSHLog/)、[WAL.swift](../Sources/PhoneDSHWire/WAL.swift)；Rust [pdsh-wal](../shell/crates/pdsh-wal/)；Kotlin [core/log](../android/core/src/main/kotlin/com/phonedsh/log/)、`dsh/host/{HostWal,WalUplink}.kt`；TS `plugins/channel/src/wal.ts` 只是**對拍 codec**，無生產消費者 | Swift `WALTests`、`PhoneDSHLogTests`；Kotlin `NativeWalGoldenTest`；Rust [golden_wal.rs](../shell/crates/pdsh-wal/tests/golden_wal.rs)（`phone-rust-tests`） |
| P03 exec／journal／handoff owner | [v1/exec.md](v1/exec.md)、[v1/handoff.md](v1/handoff.md)、[v1/budgets.md](v1/budgets.md)、[golden/perturbations](v1/golden/perturbations) | Swift [PhoneDSHController](../Sources/PhoneDSHController/)、[Handoff](../Sources/PhoneDSH/Handoff/)、[Background](../Sources/PhoneDSH/Background/)、`PhoneDSHLedger.swift`、`PhoneDSHHost.swift`；TS `plugins/{exec-bridge,tool-journal,lifecycle-gate,subprocess-xl}`；Kotlin [android/controller](../android/controller/src/main/)、`android/dsh/.../dsh/{exec,journal,background}` | `StepMachineJournalContractTests`、`SideEffectLedgerTests`、`PhoneDSHDrainRecoveryContractTests`、`plugins/tests/journal-sync.test.ts`、Kotlin `PerturbationFixtureTest` |
| P04 page bridge owner | [v1/bridge.md](v1/bridge.md)、[bridge schema](v1/schema/bridge-message.schema.json)、[golden/bridge](v1/golden/bridge) | **規範大半是 `target`**。現行 handler：`pdshNativePreview`（Swift `Sources/PhoneDSHEngine/WebEngineNativePreview.swift` ↔ [protocol.ts](../plugins/phone-native-preview/src/protocol.ts)，`legacy` 形狀）、directory import、`xlEngine` console、`pdshMcpControl`（↔ `examples/probe-app/ProbeKit/MCPControlBridge.swift`）、`pdshOpenModelSettings`（**倉內無接收端**）；Kotlin `android/engine/.../{WebViewEngine,NavigationPolicy}.kt` | bridge goldens **沒有任何 runtime 消費者**，只有 `bridge_check.py` |
| P05 HTTP／MCP gateway owner | [v1/gateway-security.md](v1/gateway-security.md)、[gateway schema](v1/schema/gateway-vector.schema.json)、[golden/gateway](v1/golden/gateway) | Swift [PhoneDSHGateway](../Sources/PhoneDSHGateway/)、Loopback 中的 HTTP 部分（`HTTPTransport`、`StreamingForward` 等；ChannelServer／WebSocket 屬 P01）；TS `plugins/llm-bridge`、`plugins/phone-mcp/src/{manager,schema}.ts`；Kotlin [android/net](../android/net/src/main/) | 只有 Kotlin `GatewayVectorConformanceTest` 讀 golden；Swift `Tests/PhoneDSHGatewayTests` 不讀 |
| P06 harness／host owner | [host/v1/README.md](host/v1/README.md)、[event-kinds](host/v1/event-kinds.md)、[host goldens](host/v1/golden) | Swift [AgentHarness](../Sources/PhoneDSHAgentCore/AgentHarness.swift)、[DSH/](../Sources/PhoneDSHAgentCore/DSH/)、`PhoneDSHEvents.swift`；Kotlin `android/core/.../{agentcore,hostevents}`、`android/dsh/.../turn` | 只有 Kotlin `HarnessKindClosureTest`、`HostEventKindSchemaTest` 讀 golden；Swift AgentCore tests 不讀 |
| P07 device／connector owner | host/v1 的 envelope／caps／receipt schema；[adapter draft](../docs/design/device-adapter-contract-draft.md)（`draft`） | Kotlin `android/domain/.../{device,connector}`；Swift `examples/probe-app/ProbeKit/Devices` | Kotlin `DeviceCapabilitiesSchemaTest`；第三方傳輸與端到端回執不由 schema 保證 |
| P08 platform owner | [platform/README.md](platform/README.md)、[whitelist](platform/whitelist.json)、[iOS audio ownership](platform/ios-audio-session.md) | Swift OS API、`Sources/PhoneDSH/Background`、`ProbeKit/PhoneAudioSessionLease.swift` 与 app 的录音／保活调用方；Android `:platform`／`:engine`／`:net` | `platform_check.py`；whitelist 不代替 conformance |
| P09 UI projection owner | [ui/v1/README.md](ui/v1/README.md)、[tokens](ui/v1/tokens.json)、[pages](ui/v1/pages)、[v1/trajectory.md](v1/trajectory.md) | iOS `examples/probe-app/PhoneDSHProbe`；Android `android/lib` | Kotlin `UiStateProjectorGoldenTest`、`TrajectoryNormalizerTest`；`ui_check.py`、`page_structure_check.py` |

### 3.2 只有 code contract 的邊界

| ID／角色 | 權威源檔（另一端跟隨它） | 另一端 | 證據與注意 |
| --- | --- | --- | --- |
| P10 workflow isolate owner | [workflow-worker/src/protocol.ts](../plugins/workflow-worker/src/protocol.ts) | 同 plugin 的 isolate | [workflow tests](../plugins/tests/workflow-worker.test.ts)。structured-clone；不傳 Agent、token、VFS handle、function；無 wire version，不冒稱 proto 1；DSH pin 升級會牽動型別 |
| P11 WASI VFS proxy owner | [vfs-protocol.ts](../plugins/wasi-toolbox/src/vfs-protocol.ts)、[types.ts](../plugins/wasi-toolbox/src/types.ts) | `vfs-server.ts`、`vfs-client.ts`、`sab-client-worker.ts`、`message-endpoint.ts` | [proxy](../plugins/wasi-toolbox/src/vfs-proxy.test.ts)、[SAB](../plugins/wasi-toolbox/src/vfs-sab.test.ts)。u32 長度是 **little-endian**，不可套用 P01 header |
| P12 native ABI owner | [shell/include/xzshell.h](../shell/include/xzshell.h) | Rust [pdsh-ffi](../shell/crates/pdsh-ffi/)、[pdsh-jni](../shell/crates/pdsh-jni/)；Swift [PhoneDSHShell](../Sources/PhoneDSHShell/)（含必須與 header 同步的 `PDSHShellCSurface.swift` stub）；Kotlin [android/shell](../android/shell/src/main/kotlin/com/phonedsh/shell/)、`core/wire/Native*.kt` | 以 [Package.swift](../Package.swift)、Android build wiring、`android/tools/check-native-alignment.py` 判斷是否真的連結；source 存在不等於可用 |
| P13 plugin Remote owner | [phone-shell](../plugins/phone-shell/src/contract.ts)、[feature-admin](../plugins/phone-feature-admin/src/contracts.ts)、[phone-mcp](../plugins/phone-mcp/src/protocol.ts)、[directory-import](../plugins/phone-directory-import/src/types.ts)、`phone-model-config/src/remote.ts`、`surface-phone/src/management-remote.ts` | Web client、Swift `PhoneDSHWorkspaceImportSink.swift` | [shell](../plugins/tests/phone-shell.test.ts)、[admin](../plugins/tests/phone-feature-admin.test.ts)、[mcp](../plugins/tests/phone-mcp.test.ts)、[import](../plugins/tests/phone-directory-import.test.ts)。至少 6 個 service 共用 `phone` namespace，**沒有方法名登記表**（GAP-10） |
| P14 DSH Remote mux owner | [ChannelDSHTransport.swift](../Sources/PhoneDSH/ChannelDSHTransport.swift)（`PhoneDSHMuxProtocol`，D22／D23） | `plugins/worker-entry/src/mux-{bridge,tunnel,json}.ts`；Swift `DSHRemoteTransport.swift`；Kotlin `android/dsh/.../turn/DshTurnClient.kt` | `/api/remote.mux`：`x-pdsh-mux-id`、`x-pdsh-mux-op`、NDJSON、4 MiB 分塊。D21–D24 不在 v1 決策表（GAP-11） |
| P15 host 控制端點 owner | Swift `Sources/PhoneDSH/{PhoneDSHWorkerCommand,PhoneDSHRecovery,PhoneDSHDescendantDrain}.swift` | `plugins/surface-phone/src/*-controller.js` | `/api/pdsh-worker-command/execute`（receipt `pdsh-worker-command/1`）、`/api/pdsh-recovery/*`、`/api/pdsh-descendant-drain`；`PhoneDSHWorkerCommandTests`、`plugins/tests/worker-command-controller.test.ts` |
| P16 Worker 啟動契約 owner | Swift `PhoneDSHWorkerEnvironment`（[PhoneDSH.swift](../Sources/PhoneDSH/PhoneDSH.swift)）、`Sources/PhoneDSHEngine/WebEngineConfiguration.swift` | Kotlin `android/engine/.../WorkerEnvironment.kt`；Worker **兩份**解析器 `plugins/worker-entry/www/boot.js`、`src/web-boot.ts`，及 `src/entry.ts` | URL 參數、init 幀、`PDSH_*` 環境變數（D24）、`__PDSH_*` 全域變數。兩份解析器必須同改 |
| P17 exec-bridge loopback owner | **權威缺失**：代碼引用的 `spec/exec-bridge-v1` 不在倉內（GAP-06）；現暫以 `plugins/exec-bridge/src/client.ts` 為準 | Swift `LoopbackServer.swift`、`ExecBridgeHosting.swift`、`PhoneDSHGateway/ModelGateway.swift` | `/v1/hello`、`/v1/exec*`、`/v1/fs*`、`/v1/lifecycle`，NDJSON |
| P18 持久化設定 owner | `/dsh/home/capabilities.json`：`plugins/worker-entry/src/capabilities.ts`；`mcp.json`：`plugins/phone-mcp/src/schema.ts`（`MCP_CONFIG_VERSION`）；`PDSH_MODEL_PROVIDER_JSON`：`plugins/phone-model-config/src/model-config.ts` | Swift `MaterializedInvariant.swift`、`ScenarioBudgets.swift`、`Sources/PhoneDSH/Phone*Settings.swift`；未查得 Kotlin 讀寫這三種設定的對應端 | 讀寫兩端、舊資料、降級一起評估；UserDefaults key 名也是協議 |
| P19 phone 工具 envelope owner | [PhoneToolEnvelope.swift](../examples/probe-app/ProbeKit/Capabilities/PhoneToolEnvelope.swift) 定義成功／失敗 envelope；Rust `shell/crates/pdsh-phone/src/lib.rs` 只定義 `phone.<tool>` 呼叫詞彙並原樣轉送結果 | Rust host bridge 消費結果；Kotlin `android/dsh/.../host/PhoneInfoTool.kt` 是獨立的 `phone info` exec 子集，回傳 exec outcome，不是同一 envelope 的實作 | Swift 成功回覆 `{ok,tool,egress,scope,data,nextCursor,truncated}`，上限 256 KiB；不據此宣稱 Kotlin envelope 對齊 |
| P20 Worker image 產物 owner | `plugins/scripts/pack-image.mjs`、[dsh-pin.json](../plugins/dsh-pin.json) | Swift `LoopbackServer.swift`；Kotlin `android/engine/.../*WorkerAssetSource.kt` | `manifest.json`、`sizes.json`、`config/vfs-manifest.json`、lazy／overlay tar |
| P21 render-media／office IR owner | [render-media-v1.md](v1/render-media-v1.md)（`draft`）、[office-ir-v1.json](v1/office-ir-v1.json) | Swift `PageSchemeHandler.swift`、`PageSurface.swift`、`ProbeKit/Office/OfficeIR.swift` | 無 gate 檢查；normative 文件已引用此 draft（GAP-09） |
| P22 scenario／perturbation fixtures owner | `spec/v1/schema/{scenario-*,perturbation,upstream-script}.schema.json` | `Sources/PhoneDSH{Scenario,Harness}`、`android/testkit`、`scripts/ci/scenarios` | `golden/upstream` 無 runtime 消費者 |

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
| P01 | `spec/v1/{channel.md,README.md}`、`spec/v1/schema/{hello,exec-req,exec-ctl,lifecycle,fence,error,console,api-*}.schema.json`、`spec/v1/golden/frames/**`、`Sources/PhoneDSHWire/**`（除 `WAL.swift`）、`Sources/PhoneDSHLoopback/{ChannelServer,DefaultChannelHandling,WebSocket,LoopbackServer}.swift`、`Sources/PhoneDSH/PhoneDSHChannel.swift`、`plugins/channel/src/**`（除 `wal*`）、`shell/crates/pdsh-wire/**`、`shell/crates/pdsh-jni/src/{lib,bridge}.rs`、`android/core/src/main/kotlin/com/phonedsh/wire/**`、`android/dsh/src/main/kotlin/com/phonedsh/dsh/host/{HostHello,HostChannel,VfsFrames,VfsSink,BootId}.kt`、`android/engine/src/main/kotlin/com/phonedsh/engine/{FrameType,HelloFields,ChannelReopenLane,ObservedChannelHandler}.kt` |
| P02 | `spec/v1/wal.md`、`spec/v1/schema/{manifest,wal-replay}.schema.json`、`spec/v1/golden/wal/**`、`Sources/PhoneDSHWire/WAL.swift`、`Sources/PhoneDSHLog/**`、`plugins/channel/src/{wal,vfs-mutation}.ts`、`shell/crates/pdsh-wal/**`、`shell/crates/pdsh-jni/src/wal.rs`、`android/core/src/main/kotlin/com/phonedsh/log/**`、`android/core/src/main/kotlin/com/phonedsh/wire/{NativeWal,WalException}.kt`、`android/dsh/src/main/kotlin/com/phonedsh/dsh/host/{HostWal,WalUplink,HostLog}.kt`、`android/engine/src/main/kotlin/com/phonedsh/engine/BootOverlay*.kt` |
| P03 | `spec/v1/{exec,handoff,budgets}.md`、`spec/v1/schema/{handoff-*,perturbation}.schema.json`、`spec/v1/golden/perturbations/**`、`Sources/PhoneDSHController/**`、`Sources/PhoneDSH/{Handoff,Background}/**`、`Sources/PhoneDSH/{PhoneDSHLedger,PhoneDSHHost,PhoneDSHLifecycle,PhoneDSHInactivity,HostFault}.swift`、`Sources/PhoneDSHAgentCore/{ExecBridgeHosting,Delegation}.swift`、`plugins/{exec-bridge,tool-journal,lifecycle-gate,subprocess-xl}/src/**`、`android/controller/src/main/**`、`android/dsh/src/main/kotlin/com/phonedsh/dsh/{exec,journal,background}/**` |
| P04 | `spec/v1/bridge.md`、`spec/v1/schema/bridge-message.schema.json`、`spec/v1/golden/bridge/**`、`Sources/PhoneDSHEngine/WebEngine*.swift`、`examples/probe-app/ProbeKit/MCPControlBridge.swift`、`plugins/phone-native-preview/src/**`、任何 `plugins/*/src/client/**` 中的 `postMessage`／`webkit.messageHandlers`、`android/engine/src/main/kotlin/com/phonedsh/engine/{WebViewEngine,WebViewKernel,NavigationPolicy,EngineCapabilities}.kt` |
| P05 | `spec/v1/gateway-security.md`、`spec/v1/schema/gateway-vector.schema.json`、`spec/v1/golden/gateway/**`、`Sources/PhoneDSHGateway/**`、`Sources/PhoneDSHLoopback/{HTTPTransport,HTTPEgressFailure,StreamingForward,Loopback,Support}.swift`、`Sources/PhoneDSHAgentCore/{Credentials,HTTPSupport,ProviderError}.swift`、`plugins/llm-bridge/src/**`、`plugins/phone-mcp/src/{manager,schema,protocol}.ts`、`plugins/worker-entry/src/model-route.ts`、`android/net/src/main/**` |
| P06 | `spec/host/v1/**`（除 `device-*`）、`Sources/PhoneDSHAgentCore/{AgentHarness.swift,DSH/**}`、`Sources/PhoneDSH/PhoneDSHEvents.swift`、`android/core/src/main/kotlin/com/phonedsh/{agentcore,hostevents}/**`、`android/dsh/src/main/kotlin/com/phonedsh/dsh/turn/**` |
| P07 | `spec/host/v1/schema/device-*`、`spec/host/v1/golden/device-*`、`docs/design/device-*.md`、`android/domain/src/main/kotlin/com/phonedsh/domain/{device,connector}/**`、`examples/probe-app/ProbeKit/Devices/**` |
| P08 | `spec/platform/**`、`android/platform*/src/main/**`、`Sources/PhoneDSHController/Signals/**`、`Sources/PhoneDSH/Background/**`、`examples/probe-app/ProbeKit/PhoneAudioSessionLease.swift`、`examples/probe-app/ProbeKit/Capabilities/PhoneMediaTools.swift`、`examples/probe-app/PhoneDSHProbe/{BackgroundKeepAlive,ComposerVoiceInput}.swift` |
| P09 | `spec/ui/v1/**`、`spec/v1/trajectory.md`、`spec/v1/schema/{trajectory,ui-state-sequence}.schema.json`、`spec/v1/golden/trajectory/**`、`examples/probe-app/PhoneDSHProbe/**`、`android/lib/src/main/**` |
| P10 | `plugins/workflow-worker/src/**`、`plugins/types/dsh-workflow-*.d.ts` |
| P11 | `plugins/wasi-toolbox/src/{vfs-*,sab-client-worker,message-endpoint,worker-scope,tool-worker-runtime,stdin-delivery,types}.ts` |
| P12 | `shell/include/**`、`shell/crates/{pdsh-ffi,pdsh-jni,pdsh-core}/**`、`shell/build-apple.sh`、`Sources/PhoneDSHShell/**`、`Package.swift`、`android/shell/src/main/**`、`android/core/src/main/kotlin/com/phonedsh/wire/Native*.kt` |
| P13 | `plugins/{phone-shell,phone-feature-admin,phone-mcp,phone-directory-import,phone-model-config}/src/{contract*,protocol,types,remote,service,index}.ts`、`plugins/surface-phone/src/management-remote.ts`、`Sources/PhoneDSH/PhoneDSHWorkspaceImportSink.swift` |
| P14 | `Sources/PhoneDSH/ChannelDSHTransport.swift`、`Sources/PhoneDSHAgentCore/DSH/DSHRemoteTransport.swift`、`plugins/worker-entry/src/mux-*.ts`、`android/dsh/src/main/kotlin/com/phonedsh/dsh/turn/DshTurnClient.kt` |
| P15 | `Sources/PhoneDSH/{PhoneDSHWorkerCommand,PhoneDSHRecovery,PhoneDSHDescendantDrain}.swift`、`plugins/surface-phone/src/*-controller.js` |
| P16 | `Sources/PhoneDSH/PhoneDSH.swift`、`Sources/PhoneDSHEngine/{WebEngineConfiguration,WebEngineScripts}.swift`、`android/engine/src/main/kotlin/com/phonedsh/engine/WorkerEnvironment.kt`、`plugins/worker-entry/{www/boot.js,src/web-boot.ts,src/entry.ts}` |
| P17 | `plugins/exec-bridge/src/{client,transport}.ts`、`Sources/PhoneDSHLoopback/LoopbackServer.swift`、`Sources/PhoneDSHAgentCore/ExecBridgeHosting.swift`、`Sources/PhoneDSHGateway/ModelGateway.swift`、`Sources/PhoneDSHShell/PDSHShellTypes.swift` |
| P18 | `plugins/worker-entry/src/capabilities.ts`、`plugins/shell-ext/src/contract.ts`、`plugins/phone-mcp/src/schema.ts`、`plugins/phone-model-config/src/model-config.ts`、`Sources/PhoneDSH/Phone*Settings.swift`、`Sources/PhoneDSHLog/MaterializedInvariant.swift`、`Sources/PhoneDSHScenario/ScenarioBudgets.swift` |
| P19 | `shell/crates/pdsh-phone/**`、`examples/probe-app/ProbeKit/Capabilities/PhoneTool*.swift`、`android/dsh/src/main/kotlin/com/phonedsh/dsh/host/PhoneInfoTool.kt` |
| P20 | `plugins/scripts/pack-image.mjs`、`plugins/dsh-pin.json`、`plugins/bundle/**`、`Sources/PhoneDSHLoopback/LoopbackServer.swift`、`android/engine/src/main/kotlin/com/phonedsh/engine/{WorkerAssets,*WorkerAssetSource}.kt` |
| P21 | `spec/v1/render-media-v1.md`、`spec/v1/office-ir-v1.json`、`Sources/PhoneDSHEngine/{PageSchemeHandler,PageSurface}.swift`、`examples/probe-app/ProbeKit/Office/**` |
| P22 | `spec/v1/schema/{scenario-*,perturbation,upstream-script}.schema.json`、`spec/v1/golden/upstream/**`、`scripts/ci/scenarios/**`、`Sources/PhoneDSH{Scenario,Harness}/**`、`android/testkit/**` |

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
