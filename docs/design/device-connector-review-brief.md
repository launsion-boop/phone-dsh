# 评审请求：设备连接器方案（给 Kimi Code / GLM 的粘贴稿）

把下面这段直接粘给评审模型即可（它和你在同一个工作区）。

---

你是资深工程负责人，评审一份设备连接器架构方案。标准是「三周能不能出货、能不能复用现有代码、数字和接口是否具体」，**不要风险清单，不要合规说教，不要复述方案**。

先读：

1. `docs/design/device-connector-2026-10-31.md`（主方案）
2. `docs/design/device-adapter-contract-draft.md`（适配器契约）
3. 现有实现（判断方案是否忽略了可复用资产）：
   - `../xiaozhi-link/sdk/Sources/XiaozhiLinkCall/`（CallController / CallAudioUplink / CallBridgeCoordinator）
   - `../xiaozhi-link/firmware/components/xl_call/`（通话状态机）与 `../xiaozhi-link/NOTES-f4-call.md`
   - 自有设备固件的 `docs/voice-device-control-handoff.md`、实时客户端的 `connections/chat-server/devicews/PROTOCOL.md`
   - `../tono-account/docs/DEVICE-API.md`（设备 attest / 6 位配对码 / 设备 token）
   - CallMate（EchoCard）远端的 `docs/ARCHITECTURE.md`、`docs/AUDIO_PIPELINE_LATENCY_PLAYBOOK.md`、`docs/ANCS_SINGLE_SUBSCRIBER_PER_PHONE.md`
   - `examples/probe-app/ProbeKit/Devices/`（现有只读设备会话）

已定约束：ESP32 纯终端；语音出局域网、走自有服务器做 ASR/TTS 并计量；服务端中继为主路径，手机 DSH 作为云 LLM 的工具（可选当主脑）；渲染四类（灯效/像素屏/墨水屏/普通屏）；通话是既有强项（HFP 中继 / BLE call_up / USB UAC2，Agent 可混音加入）；开放协议由同事负责，只预留适配器。

请输出（≤1200 字）：

1. 最不工程化的 3 个地方（指到章节），各给可落地的替代设计（接口/字段/时序/数字）。
2. 被低估或漏掉的现有资产（具体到文件/类型），以及怎么接。
3. 服务端中继的细节：鉴权、配额、计量、DSH 离线回落、长任务两段式——指出没想清楚的点，给出你的做法。
4. 通话：三条承载怎么统一抽象；混音、回声、打断、延迟的参数与坑。
5. 渲染四类：最省事的统一表示与降级链。
6. 只做三周 v0：砍什么、留什么、按什么顺序。
7. 一句话：这份方案最大的工程错误是什么。

每条尽量给证据（文件/行号/协议字段）；没证据的判断标注「推测」。
