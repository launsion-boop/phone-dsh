# PC-20261112-android-voice-consumer — Android as a TonoLink voice / cloud-voice consumer

## 0. 摘要（机器可读，保持这个格式）

```yaml
change: PC-20261112-android-voice-consumer
contracts: [P07, P05]
status: draft
breaking: false
version_decision: 不改 wire／版本。Android 是 tonolink-board.md §4.1 与 cloud-voice.md 同一批字节的另一个 consumer；本次只登记 consumer、Android 背景/API floor 陈述和 device-only 验收字段，没有新字段、新消息、新错误码或新端点。
base: 9af4d7f3483cbd51a4847fd25fb7ea860a6f6966
contract_revision: 尚未冻结；P07/P05 contract owner 套用 §2 后填 spec/device/v1/tonolink-board.md@<rev> 与 spec/v1/cloud-voice.md@<rev>
```

本单是 **draft**（AGENTS.md §3.1 的 contract freeze 之前一步）：它只提出 D-12（把 Android 登记为
consumer）和 D-14（后台验收记为 device-only），记录 P05 的 Ktor client 依赖决定，并说明 2B.1/2B.2
交付后 Android **只有 JVM 两半，还不是 consumer**。本单不修改 `spec/**`；owner 套用后才成为 frozen
revision。

## 1. 识别与角色

- **Trigger → 现况 → 期望**
  - Trigger：`spec/device/v1/tonolink-board.md:3` 写 `implemented`（iOS consumer only；§4.1 为
    `partial`），`:14` 写 “Android and HarmonyOS have no consumer”；`spec/v1/cloud-voice.md:3`
    写 `partial`（iOS consumer only），`:14` 同样写 Android/HarmonyOS 无 consumer。
    `spec/platform/whitelist.json` 的 `platform.tonolink-voice-background-wake` 也写
    “Android has no TonoLink voice consumer”。
  - 现况：Android 有 `:domain` 的 BLE 编解码与 `:net` 的 loopback/gateway，但没有 TonoLink
    ctrl 服务、没有 `TonoLinkVoice`、没有 cloud ASR/TTS 客户端；`android/README.md` 的模块表也不含
    这些路径。
  - 期望：Android 用同一批 §4.1 与 cloud-voice 字节实现第二个 consumer。2B.1 交付 wire codec
    （event 行、audio 包、`listen`、tally，`android/domain/.../tonolink/TonoLinkVoice.kt`）；2B.2
    交付 cloud-voice 的 JVM 客户端（`android/net/.../voice/**`）。3A.1–3A.3 才做 ctrl GATT adapter、
    foreground service 和整轮状态机，并产生真机证据。**本次不碰 `:app`，不碰 Swift，不改 wire。**
- **Coordinator / contract owner**：P07 + P05 owner（本单作者只起草，不套用 spec）。
  Implementers：2B.1/2B.2 = 本单作者；3A.1–3A.3 = 后续 Android voice worker。
  Reviewer-integrator：不得是同一端的实作者（AGENTS.md §3.4）。
- **Owning spec / fixtures**：`spec/device/v1/tonolink-board.md` §4.1 +
  `spec/device/v1/golden/tonolink-voice.json`；`spec/v1/cloud-voice.md` +
  `spec/v1/golden/cloud-voice/cases.json`；平台陈述归 `spec/platform/whitelist.json`（P08）与
  `spec/platform/ios-audio-session.md`（D-13）。本次**不改**这些文件。
- **受影响的 producer／consumer（逐端）**
  - 板子固件（`tonolink-m21-r4-firmware@4763811`，仓外）：不改。§4.1 已冻结；Android 只读同样的
    status/audio notify 并写 `<seq> listen <id>`。
  - 云端服务（`TonoTeam/phone-dsh-cloud@64a3d2098ca2` 的 `contracts/`）：不改。Android 只是另一个
    `pdsh-asr.v1` WebSocket 与 `/v1/tts/speech` HTTP 客户端。
  - iOS（`Sources/PhoneDSHBLE/TonoLinkVoice.swift`、`Sources/PhoneDSH/CloudVoice/**`）：不改，只作
    参考实现与出处。
  - Android（新）：`:domain` 的 `com.phonedsh.domain.device.tonolink`；`:net` 的
    `com.phonedsh.voice`；`:net` build 的 Ktor client 依赖。`:app`、`:lib`、`:dsh` 不改。

## 2. 契约 delta（proposals，owner 套用）

只列要改的条款；未变语义引用 owning clause。所有行号以本单 base `9af4d7f3` 为准。

| 项目 | Before → After／依据条款 |
| --- | --- |
| D-12（P07）consumer 登记 | `tonolink-board.md:14` “Android and HarmonyOS have no consumer.” → HarmonyOS 仍无 consumer；Android 有 §4.1 wire codec 与 cloud-voice JVM 客户端，但**没有** ctrl adapter / FGS / turn，因此此刻还不是整轮的 consumer（§2.1.1） |
| D-12（P07）背景陈述 | §4.1 Consumer rules 增加 Android 段：`ev wake` 只在 voice foreground service 运行时可用；service 没启动就没有 wake；API 26 floor，API 29+ 的 typed `startForeground` 与 `connectedDevice` type 是分支而不是策略差异（§2.1.1） |
| D-12（P05）cloud-voice consumer 登记 | `cloud-voice.md:14` 同样把 Android 列为 JVM 客户端端；status 仍 `partial`，直到真机整轮证据（§2.1.2） |
| D-14（P07/P08）后台验收 | 不新增共享 golden；“app background”验收是 **device-only record**，字段与通过条件见 §2.2 |
| P05 依赖决定 | Ktor client 3.2.3（`ktor-client-core`、`ktor-client-cio`、`ktor-client-websockets`）从 `:net` 的 `testImplementation` 提升为 `implementation`；不手写 RFC 6455，不加第二个依赖（§2.3） |
| wire／schema／golden | **不变量**。没有新字段、新消息、新错误码；Android 必须逐字节通过既有 golden |

自检（对照 `spec/README.md` §5.1）：没有新增第二种表达；没有新字段；没有收紧或放宽两端都读的
消息；没有新增 enum/错误码/capability；没有删除或重用任何名称或编号。唯一的“状态”争议是 Android
的 consumer 文案，本单用“JVM halves / 不是整轮 consumer”明确区分，不把 `implemented` 提前。

### 2.1 要套用的条款（quote → replacement）

#### 2.1.1 P07 — `spec/device/v1/tonolink-board.md`

`tonolink-board.md:3`（现状）：

> ```text
> Status: `implemented` (iOS consumer only; §4.1 voice turn `partial` until device evidence).
> ```

改为：

```text
Status: `implemented` (iOS consumer; §4.1 voice turn `partial` until device evidence).
Android implements the §4.1 wire codec and the cloud-voice consumer subset
(`android/domain/.../tonolink/TonoLinkVoice.kt`, `android/net/.../voice/**`), but
has no ctrl GATT adapter, voice foreground service or turn yet, so it is not a
consumer of the turn until 3A.1–3A.3 have device evidence.
```

`tonolink-board.md:14`（现状）：

> ```text
> The consumer is `Sources/PhoneDSHBLE/TonoLink*.swift` plus
> `Sources/PhoneDSHVenus/IPhoneAgent*.swift`. Android and HarmonyOS have no consumer.
> ```

改为：

```text
The consumer is `Sources/PhoneDSHBLE/TonoLink*.swift` plus
`Sources/PhoneDSHVenus/IPhoneAgent*.swift`. HarmonyOS has no consumer. Android has
the JVM halves — the wire codec in `android/domain/.../tonolink/TonoLinkVoice.kt`
and the cloud-voice client in `android/net/.../voice/**` — but no ctrl GATT
adapter, no voice foreground service and no turn; it becomes a consumer of the
turn only when those land with device evidence.
```

§4.1 “Consumer rules”段（现状末句 “The phone keeps this link while in the background …”）之后追加：

```text
**Android background statement.** Android has no Core Bluetooth restore and no
iOS background mode: `ev wake` is available only while the voice foreground
service runs. The service is started while the user is in the app (Android 12+
forbids starting it from the background, and a BLE notification cannot start
one); if it was never started, wake is unavailable and the UI must say so — this
is a user-visible platform difference, not a hidden fallback. The service holds
the ctrl link for the life of the turn. Android's floor is API 26. The
`connectedDevice` foreground-service type and the typed
`startForeground(id, notification, type)` call are API 29+; below 29 the manifest
type is ignored and the untyped `startForeground(id, notification)` is used. The
branch is in the call, not in this policy.
```

（音频输出、无 AirPlay override、media focus、无手机录音属于 D-13 / P08 的 Android audio note；
本单不把它塞进 §4.1，避免第二份表达。）

#### 2.1.2 P05 — `spec/v1/cloud-voice.md`

`cloud-voice.md:3`（现状）：

> ```text
> Status: `partial` (iOS consumer only, until device evidence).
> ```

改为：

```text
Status: `partial` (iOS consumer and an Android JVM client, until device evidence).
```

`cloud-voice.md:14`（现状）：

> ```text
> The consumer is `Sources/PhoneDSH/CloudVoice/**`; the caller is the TonoLink voice turn
> ([tonolink-board.md](../device/v1/tonolink-board.md) §4.1). Android and HarmonyOS have no consumer.
> ```

改为：

```text
The consumer is `Sources/PhoneDSH/CloudVoice/**`; the caller is the TonoLink voice turn
([tonolink-board.md](../device/v1/tonolink-board.md) §4.1). The Android JVM client is
`android/net/src/main/kotlin/com/phonedsh/voice/**` (same start/finish/cancel
messages, same message classification, same TTS body, same 100-body pre-start
queue and deadlines); it has no turn host yet, so Android has no device evidence
and the status stays `partial`. HarmonyOS has no consumer.
```

#### 2.1.3 P08 — `spec/platform/whitelist.json`（建议的 `android` 字段）

现有条目 `platform.tonolink-voice-background-wake` 的 `android` 是 “Android has no TonoLink
voice consumer; a future one would hold the BLE link in the existing foreground service instead
of a background mode.” 建议 owner（P08）替换为：

```text
Android holds the TonoLink ctrl link in a voice foreground service while the
user has voice enabled. The service is started only while the app is in the
foreground; `ev wake` is available only while it runs, and a wake that arrives
with no service is lost. The FGS type is `connectedDevice` on API 29+ and the
untyped `startForeground` is used on API 26–28. Audio playback is the media
route (`AudioTrack`, `USAGE_MEDIA`, `CONTENT_TYPE_SPEECH`, transient-may-duck
focus), with no AirPlay speaker override and no phone microphone capture.
```

`evidence_level` 在 3A.3 真机验收前保持 `not-verified`，`rationale` 保留“未验证”。这行不改变任何
wire；它只是把已经存在的条目从“没有 consumer”改成“有 JVM 客户端、平台半尚未验收”。

### 2.2 D-14 — 后台验收是 device-only record，不是共享 golden

**决定**：voice turn 的 “app background” 验收（wake while screen off、FGS 类型/通知、音频路由、
Doze）**不**新增 `spec/**/golden` 文件。理由是这些字段是平台生命周期属性，不是两端都要解码的
wire；共享 golden 应只覆盖字节。3A.3 在 `docs/design/android-device-port-plan.md` §3.5.6 的检查点
记录里填下列字段，并在 `spec/device/v1/tonolink-board.md` §4.1 的 evidence 句引用该记录：

| 字段 | 取值／通过条件 |
| --- | --- |
| device / build | 机型、Android release、API level、app versionName + git SHA |
| board | 板子名/固件版本、`/v1/info` `features` 的 `wake` 位 |
| FGS | service 是否启动、类型（API 29+ `connectedDevice`）、通知是否可见、API 26–28 的未类型化分支是否走到 |
| screen | 亮屏 / 熄屏 / 锁屏；wake 在熄屏时是否到达 |
| Doze | `dumpsys deviceidle` 状态；idle 下是否仍到达（允许延迟，不允许伪造） |
| latency | `ev wake` 到「我在」开始播放的毫秒数；`listen` 写出时刻 |
| ASR | connect/started ms、`started` 是否在 5 s 内、`finish` 到终态用时 |
| audio | 实际输出路由（speaker/headphones/A2DP）、focus 获取/放弃、focus loss 是否停止播放 |
| result | 整轮成功／失败分类；失败时是否有文本被误用 |
| negative | service 未启动时的 wake 行为：不可用且 UI 说明，不得静默假装支持 |

通过条件：至少一次“FGS 运行 + 熄屏”到达 `ev wake` 并完成到 ASR outcome；一次“FGS 未启动”证明
wake 不可用且 UI 如实说明；一次 focus loss 停止播放。`NOT_RUN` 就是 `NOT_RUN`，JVM 测试不能
升级成 device 证据。

### 2.3 P05 依赖决定（已由 P05 owner 在本任务前做出，本单只记录）

- 采用 Ktor **client** 3.2.3：`io.ktor:ktor-client-core:3.2.3`、`ktor-client-cio:3.2.3`、
  `ktor-client-websockets:3.2.3`，在 `android/net/build.gradle.kts` 从 `testImplementation`
  提升为 `implementation`。版本与同一 build file 的 Ktor server 3.2.3 相同；理由与注释已在
  `:net` build file 中（Kotlin 2.1.0 编译器可读 3.2.3 的 metadata）。
- **不**手写 RFC 6455，**不**新增其它依赖（无 OkHttp、无序列化库）。JSON 复用 `:net` 既有的
  `com.phonedsh.gateway.GatewayJson`（`JsonValue`），不引入第二份 JSON 库。
- 传输放在两个小接口后：`CloudVoiceSocketFactory`/`CloudVoiceSocket`（ASR）与
  `CloudTtsTransport`（TTS）。session/TTS 状态机只用接口，测试用 fake socket；
  `KtorCloudVoiceSocketFactory`/`KtorCloudTtsTransport` 是唯一 Ktor adapter。
- 真机路径证据：`KtorCloudVoiceTransportTest` 用本地 Ktor **server**（`embeddedServer(CIO)`）
  跑真实 client，断言 `Sec-WebSocket-Protocol: pdsh-asr.v1`、`Authorization: Bearer`、
  `start` → `started` 的顺序、`started` 前的 binary 不出门、`finish`/`cancel` 与 normal close
  (1000)，以及本地 HTTP TTS 的 PCM 重分块。测试不解析真实主机名，不访问 `pdsh.tonoai.cn`。
- 凭据：`CloudVoiceCredentialProvider` 是注入接口，`CloudVoiceCredential.resolve` 是 §1 的纯
  决策；`:net` 不读 account storage。TTS 401 的 `CloudVoiceException.isCredentialExpired` 与 ASR
  `handshakeStatus` 是给 3A.3 的输入；§1 的“invalidate once + 仅当新值不同才重发一次”属于 turn
  host（iOS 同样在 `TonoLinkVoiceHost` 做），不在 2B.2 的 client 内隐式重试。
- Ktor client 的 TLS 使用 JVM 默认 trust store（与 iOS URLSession 的默认信任一致）；没有 pinning，
  没有自签例外。真实 WSS 主机仍是 3A.3 的 device/E2E 证据。

## 3. 相容性与发布

### 3.1 为什么没有 wire change

| 字节面 | 条款 | Android 做法（与 iOS 相同） |
| --- | --- | --- |
| `ev wake` / `ev listen_end` | §4.1 | 严格十进制、未知 `key=value` 忽略；缺成员/非十进制/未知 reason 不是事件 |
| `<seq> listen <id>` | §4.1 | 十进制、无换行、id 1…2³²−1；id 0 本地拒绝 |
| audio packet | §4.1 | 4 字节头、LE seq、flags bit0/bit1、id 低 8 位匹配、0…160 Opus；gap 计数不补 |
| ASR `start`/`finish`/`cancel` | cloud-voice §2 | 同一 JSON 对象、同一 `pdsh-asr.v1` 子协议、同一 100 包队列上限 |
| ASR results | cloud-voice §2 | `partial` 只显示不使用；final 按 `segment_id` 排序且只在 `completed` 后用 |
| TTS body / PCM | cloud-voice §3 | `input`/`voice`/`response_format: pcm`；16 kHz mono s16le 整样本重分块 |

### 3.2 相容性矩阵

| Producer → Consumer | 支持／拒绝方式及理由；对应测试 |
| --- | --- |
| 板子固件 4763811 → Android codec | 支持。只读 §4.1 的两条 status 与 audio notify；未知成员忽略。测试：`TonoLinkVoiceGoldenTest` 全 16/2/8 行。 |
| 云端 pdsh-asr.v1 v0.2 → Android session | 支持。未知非终态 type 忽略；未知终态形状 invalid。测试：`CloudVoiceGoldenTest` server_messages 16 行 + `CloudASRSessionTest`。 |
| 云端 TTS `/v1/tts/speech` → Android client | 支持。非 200 是失败，不重试；流中断即停止。测试：`CloudTTSClientTest` + 本地 Ktor server。 |
| iOS/Android 之间 | 无直接链路；两者是同一板子/云端的独立 consumer，不互读本地状态。 |
| old → new（Android 首次发布） | Android 之前没有 voice 数据；没有 migration。 |
| new → old（Android 回滚到无 voice 的 build） | 无持久化数据；回滚只少功能。板子/云端不受影响。 |
| new → new（iOS 与 Android 并存） | 两个独立连接；板子同一时刻只有一条 ctrl 链路（3A.1 负责），云端按 session 计费。 |
| version / adapter | 不加版本、不加 adapter。§4.1 与 cloud-voice 字节不变；Android `minSdk 26`。 |

### 3.3 发布顺序与回滚

1. Owner 套用 §2.1 的 P07/P05 文本（同一 revision），并让 P08 更新 whitelist 的 Android 行。
2. 2B.1/2B.2 落在 `:domain`/`:net`，不启用任何 UI、不启动 service。
3. 3A.1–3A.3 才加 ctrl adapter、FGS、turn；它们各自需要 device evidence。
4. 回滚 2B.1/2B.2：删除 `:net` 的 voice 包与 `:domain` 的 tonolink 包，Ktor client 依赖退回
   `testImplementation`；没有持久化数据要清。
5. Android 在 3A.3 之前**不得**把 `tonolink-board.md` / `cloud-voice.md` 的 status 升级，也不得在
   UI/设置里宣称 voice 可用。

## 4. 分工与证据

### 4.1 本任务（2B.1 / 2B.2）

| 检查点 | 独占路径 | 共享 golden | 验收 |
| --- | --- | --- | --- |
| 2B.1 | `android/domain/src/main/kotlin/com/phonedsh/domain/device/tonolink/TonoLinkVoice.kt` + 对应 test | `spec/device/v1/golden/tonolink-voice.json` | `:domain:testDebugUnitTest` |
| 2B.2 | `android/net/src/main/kotlin/com/phonedsh/voice/**` + 对应 test；`:net` build 的 client 依赖提升 | `spec/v1/golden/cloud-voice/cases.json` | `:net:test` |

`:net` 是 `java-library`，没有 `testDebugUnitTest`；本任务用实际存在的 `:net:test`。`:domain` 是
Android library，用 `:domain:testDebugUnitTest`。

### 4.2 共享 fixtures 的真实执行行数

| 测试 | section | 行数 | 说明 |
| --- | --- | --- | --- |
| `TonoLinkVoiceGoldenTest` | `constants` | 5 | header/opus/frame/flag 常量 |
| | `events` | 16 | 含 3 条 `ev wake`、5 条 `ev listen_end`、8 条拒绝行 |
| | `listen_commands` | 2 | 含 id=0 的本地拒绝（额外断言） |
| | `packets` | 8 | 4 条有效 + 4 条拒绝（短包、缺 Opus/缺 last、超长、错 id） |
| `CloudVoiceGoldenTest` | `constants` | 11 | 与 `CloudVoice` 常量逐项相等 |
| | `start` | 1 | 结构相等（`GatewayJson.structuralEquals`） |
| | `credentials` | 9 | 纯 §1 决策 |
| | `server_messages` | 16 | 真实分类器，含 invalid/ignored |
| | `transcripts` | 7 | 真实 transcript，含 close/error/cancelled/no_speech |
| | `speakable` | 5 | 真实去 Markdown/折叠空白 |
| | `chunks` | 4 | 真实 scalar 切分，含 `joined == input` |
| `CloudASRSessionTest` | failure paths | 11 tests | started gate、顺序、queue cap 101、connect/started/finish deadline、close、401、cancel |
| `CloudTTSClientTest` | PCM/请求/错误 | 6 tests | 7000/7001 整样本、半样本丢弃、401、流中断、1…1000 scalar、无凭据 |
| `KtorCloudVoiceTransportTest` | 真实 client | 4 tests | 本地 Ktor server：subprotocol、Bearer、ordering、cancel/close 1000、401、TTS PCM |

### 4.3 命令 → 结果

环境：本 worktree `dsh/20261111-204055/04-05-voice-jvm-halves`，base `9af4d7f3`，
`bash android/tools/with-android-toolchain.sh`（JDK 17，Gradle 8.13，Ktor 3.2.3）。

| 命令 | 结果 |
| --- | --- |
| `bash android/tools/with-android-toolchain.sh ./gradlew :domain:testDebugUnitTest --tests 'com.phonedsh.domain.device.tonolink.TonoLinkVoiceGoldenTest' --no-daemon` | PASS（5 tests；见 §4.4） |
| `bash android/tools/with-android-toolchain.sh ./gradlew :net:test --tests 'com.phonedsh.voice.*' --no-daemon` | PASS（4 classes / 30 tests；见 §4.4） |
| `bash android/tools/with-android-toolchain.sh ./gradlew :domain:testDebugUnitTest :net:test --no-daemon` | PASS（`:domain` 179 tests、`:net` 291 tests，0 failures/0 errors/0 skipped） |
| `bash scripts/ci/check.sh --only phone-android-structure,phone-cross-tree,phone-spec` | **PASS**（`phone-spec` 21s、`phone-cross-tree` 28s、`phone-android-structure` 148s；无 GAP-35/hygiene 红进入本组） |

### 4.4 结果细节（本次实际输出）

- `:domain:testDebugUnitTest --tests ...TonoLinkVoiceGoldenTest` → `BUILD SUCCESSFUL`；
  `TonoLinkVoiceGoldenTest.xml` `tests=5 failures=0 errors=0 skipped=0`。
- `:net:test --tests 'com.phonedsh.voice.*'` → `BUILD SUCCESSFUL`；
  `CloudVoiceGoldenTest` 9/0/0/0，`CloudASRSessionTest` 11/0/0/0，`CloudTTSClientTest` 6/0/0/0，
  `KtorCloudVoiceTransportTest` 4/0/0/0（30 tests）。
- 全模块 `:domain:testDebugUnitTest :net:test` → `BUILD SUCCESSFUL`（`actionable tasks: 3 executed`）；
  `:domain` 19 个 class 共 179 tests、`:net` 29 个 class 共 291 tests，全部 0 failures/0 errors/0 skipped。
- `bash scripts/ci/check.sh --only phone-android-structure,phone-cross-tree,phone-spec` →
  `== CI GATE: PASS`（三 stage 全 PASS；本组没有出现 GAP-35/hygiene 红）。
- 注意（诚实记录）：开发中一次本地 TTS 测试在 `CloudTTSClient` 还没有 URL 注入点时访问了
  `https://pdsh.tonoai.cn/v1/tts/speech`，被真实主机以 `401 invalid_credential` 拒绝。请求只含
  合成 token `tok-local` 与文本「你好」，没有真实凭据/用户数据。已给 client 加 test-only URL
  注入，提交的测试此后只用本地 Ktor server 或 fake；本记录不把那次请求当证据。

### 4.5 剩余风险与未决

1. **3A.1 ctrl adapter 仍是硬前置**：2B.1 只证明字节层；没有 GATT 写/通知、seq/ack、加密要求，
   整轮不能跑。`cmd` 写错误必须 fail closed（未到的 ack 是失败，不重试）。
2. **3A.2 FGS 仍是平台前置**：API 26 的未类型化 `startForeground` 与 API 29+ 的
   `connectedDevice` 分支只在 manifest/真机上可见；JVM 测试证明不了。`FOREGROUND_SERVICE_CONNECTED_DEVICE`
   （API 34+）与通知渠道属于 3A.2。
3. **Doze/OEM**：`ev wake` 在 Doze 下可能延迟；FGS 是唯一缓解，OEM battery manager 不在契约内。
4. **Ktor TLS 真机行为**：JVM 默认 trust store 与 Android 的 TrustManager 在真机上的证书链/代理
   行为未验证；若真机 TLS 失败，退回其它 client 是另一个 P05 dependency decision（不在本单冻结）。
5. **凭据失效重试**：§1 的“invalidate once + 仅当新值不同才重发一次”在 3A.3 的 turn host，不在
   2B.2；本单只提供 `handshakeStatus` 与 `isCredentialExpired`。
6. **未跑真机**：本单所有结果都是 JVM/本地 stub；wake while screen off、audio route、通知、Doze
   都是 `NOT_RUN`，不得写成 PASS。
7. **既有红门禁**：`phone-p0-conformance` 的 page-structure（GAP-35，PCLink 页，6 处）与
   `phone-hygiene` 的既有 findings 与本单无关；不修、不放宽。

## 5. 修订纪录

| revision | 由谁 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| draft-1 | 本单作者（非 owner） | 初稿：D-12（P07/P05 consumer 登记 + Android 背景/API floor）、D-14（device-only 验收）、Ktor client 依赖决定、2B.1/2B.2 证据 | P07/P05 owner、P08 owner、Android parity、3A.x workers |
