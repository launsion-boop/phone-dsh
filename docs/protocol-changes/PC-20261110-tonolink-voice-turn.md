# TonoLink 板子语音：「你好小智」→「我在」→ 板子录音 → 云端识别 → 聊天 → 朗读回复（P07／P05／P08）

```yaml
change: PC-20261110-tonolink-voice-turn
contracts: [P05, P07, P08]
status: implemented
breaking: false
version_decision: Consumer-only. Registers the board's existing voice turn (ev wake, listen, audio packets, ev listen_end; firmware unchanged) and the phone's subset of the cloud's pdsh-asr.v1 and /v1/tts/speech (cloud contract unchanged). Adds one keep-alive owner and no wire field, frame type, error code, UserDefaults key or Package.swift product.
base: 6f4bed1f
contract_revision: spec/device/v1/tonolink-board.md §4.1 + golden/tonolink-voice.json; spec/v1/cloud-voice.md + golden/cloud-voice/cases.json; spec/platform/ios-audio-session.md §1–§2 @ this PR head
```

Protocol impact: P05; P07; P08; P09: none — no page, row or copy changes, the voice turn has no UI in this revision; P18: none — no new UserDefaults or Keychain key, the tono-account edit only points to the voice credential rule; P27: none — the app files touched add the voice host and its DEBUG routes, PC Link is unchanged

P05 — new consumer `Sources/PhoneDSH/CloudVoice/**` of the cloud ASR (WebSocket) and TTS (HTTP), with the credential rule of tono-account.md §4/§5. P07 — the board voice turn on the ctrl GATT service, consumer `Sources/PhoneDSHBLE/TonoLinkVoice.swift` and the app's `TonoLinkVoiceHost.swift`, plus four DEBUG relay routes. P08 — the voice turn is a third keep-alive owner and plays TTS through its own AVAudioEngine without touching the session category.

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 要像 xiaozhi-link 一样：对 TonoLink 板子说「你好小智」，手机说「我在」，接着说的话由板子的麦克风录下、Opus 编码经 BLE 给 Phone DSH，DSH 执行（开灯、打开电池看电量……）并朗读结果。现况：板子固件（`tonolink-m21-r4-firmware@4763811`，移植自 xiaozhi-link `agent_s3`）已有唤醒、`listen` 录音和 20 ms Opus；手机侧没有任何消费者，云端 ASR／TTS 也没有客户端。
- **Roles.** 单一 agent 兼 coordinator／contract owner／implementer／reviewer（AGENTS.md §3）。
- **Ends.** Producer：板子固件（不改）；云端服务 `TonoTeam/phone-dsh-cloud@64a3d2098ca2` 的 `contracts/`（不改）。Consumer：iOS（本 PR）。Android／HarmonyOS 无消费者。

## 2. Delta

| 项 | Before → After |
| --- | --- |
| 板子语音（P07） | 未登记 → tonolink-board.md §4.1：`ev wake n= up=`、`<seq> listen <id>`、audio 包 `[seq u16 LE][flags][id&0xFF][Opus]`、`ev listen_end n= frames= reason=`，非法行／包的处理，共享样例 `golden/tonolink-voice.json`。 |
| 云端语音客户端（P05） | 无 → cloud-voice.md：凭据（登录用 access token；未登录仅当所选模型服务的 origin 正好是云端时用其密钥；其他一律不发）、ASR start 报文与结果规则（只在 `completed` 后用 final 文本）、TTS pcm 流式播放与分段、取消。共享样例 `golden/cloud-voice/cases.json`。 |
| 凭据（P05） | tono-account.md §4 只列模型与搜索 → 加一句：云端语音同一优先级，未登录的后备见 cloud-voice §1。 |
| 音频会话（P08） | keep-alive owner：聊天、DEBUG relay → 加上「板子已连接且有唤醒词」时的语音。TTS 用自己的 AVAudioEngine 播放，不改 category、不激活、不录音。 |
| DEBUG relay（P07） | 加 `GET /debug/voice`、`POST /debug/voice/wake`、`POST /debug/voice/say`、`POST /debug/voice/opus[?chat=1]`。 |

Self-check：没有第二种 envelope、别名或错误码；板子与云端线格式都不变；4 字节 BLE 头从不离开手机（云端协议禁止 BLE 头）；partial 永不执行；识别失败或不完整时不发消息、不重放音频。

## 3. 相容性

| Producer → Consumer | 行为 |
| --- | --- |
| 无唤醒词的板子 → 新 App | 永远不会收到 `ev wake`；只建立 ctrl 连接，不录音。`listen` 被拒（`ack err`）时本轮结束，不发任何东西。 |
| 新固件（加字段）→ 新 App | 已知成员之后的未知 `key=value` 忽略。 |
| 旧 App → 任意固件 | 不订阅 audio，板子照旧（固件不订阅即不发）。 |
| 云端 pdsh-asr.v1 加可选字段 | 忽略未知可选字段与未知非终态类型。 |
| 回滚 | 无持久化数据；回滚只少了语音功能。 |

## 4. 证据

- Swift：`swift test --filter 'PhoneDSHBLETests.TonoLinkVoiceTests'` → 5 passed；`swift test --filter 'PhoneDSHTests.CloudVoiceTests'` → 9 passed（共享样例跑真实解析器／构造器；TTS 经 URLProtocol 桩）。
- iOS：`xcodebuild … generic/platform=iOS`（Q322S2LD93）→ BUILD SUCCEEDED，新文件无警告。
- 设备（longshu 上的 iPhone，板子 PhoneAgent-7356，固件 4763811）：
  - 启动后自动连上 ctrl 服务、订阅 audio、keep-alive 开启。
  - 板子控制台 `wake`（模拟）→ 手机收到 `ev wake n=0` → 预取的「我在」0.75 s 播完、ASR 同时就绪 → `listen` → 板子 286 帧、0 缺号、0 丢包，全部转发 → `ev listen_end reason=vad` → 云端无可识别语音，本轮静默结束。
  - `POST /debug/voice/opus`（macOS `say` 合成「打开电池，看看现在的电量」→ libopus 16 kHz 20 ms，207 包）→ 云端 ASR「打开电池看看现在的电量。」
  - `POST /debug/voice/opus?chat=1`（「把板子上的灯打开」）→ 聊天 → `ble_link_call light.set {"on":true}` → `completed`、`ws2812` → 回复「灯已打开」朗读（代码块不读），9.3 s。
- 真人：对板子说「你好小智」→ `ev wake n=10` → 我在 → ASR 连接 179 ms、started 412 ms → 570 帧 0 缺号 0 丢包 → 识别「连接网络，提供语音服务，已连接。」→ 聊天回复并朗读（rev 2）。
- 未验证：后台／锁屏下的整轮；「打开电池查看电量」整轮（需要屏幕镜像开着，`iphone_agent_run` 才看得到屏幕）；固件 Kconfig 帮助文字仍写「listen 未移植」，但代码与本次实测表明已移植（属固件仓库文档，未改）。

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知 |
| --- | --- | --- | --- |
| 1 | Claude | 初版 | iOS；固件与云端不变 |
| 2 | Claude | 真机：手机网络慢时 ASR 连接本身就用完 5 s，`started` 截止误判。改为连接 10 s、`start` 写出后 5 s 等 `started`（云端自己的 5 s）；加 USB 可读的语音日志（DEBUG）。真人「你好小智」整轮通过：连接 179 ms、started 412 ms、570 帧 0 丢包、识别出话、聊天回复并朗读。 | iOS |
