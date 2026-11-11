# 语音轮次：「我在」之后立即录音，不等云端识别就绪（P05／P07）

```yaml
change: PC-20261111-voice-record-before-asr-ready
contracts: [P05, P07]
status: implemented
breaking: false
version_decision: Timing change inside the existing voice turn (cloud-voice.md §2, tonolink-board.md §4.1). No wire, message, field or code change; the cloud still never receives audio before `started`.
base: e223d399
contract_revision: spec/v1/cloud-voice.md §2; spec/device/v1/tonolink-board.md §4.1 consumer rules @ this PR head
```

Protocol impact: P05; P07; P09: none — no page, row or copy changes; P27: none — TonoLinkVoiceHost.swift reorders the voice turn only, PC Link is unchanged

P05 — the board's Opus bodies may now wait on the phone longer than 2 s before `started`; they are still sent only after `started`, in order. P07 — the phone writes `listen` as soon as 「我在」 has played instead of after the cloud ASR is ready.

## 1. 问题

真机：第一轮（打开设置）成功后，App 进入后台（设置在前台），第二轮唤醒时云端识别 2.35 s 才就绪（第一轮 0.76 s）。手机等识别就绪才发 `listen`，「我在」播完后约 1.6 s 没有录音；用户在这段时间说完了话，板子随后 5 s 只录到静音（`reason=no_speech`），识别为空，这一轮没有反应。

## 2. Delta

| 项 | Before → After |
| --- | --- |
| `listen` 时机 | 等 ASR `started` 之后 → 「我在」播完立即 |
| 板子音频 | 只在 ASR 就绪后才产生 → 先存在本轮流里（最多 700 包 = 14 s，大于板子 12 s 一轮），`started` 后按序发送 |
| 云端看到的 | 不变：`started` 之前不发音频；音频始于 `start` 之后，不会超前实时 |

## 3. 相容性

纯手机端时序；云端与固件不变。ASR 最终没连上时，本轮仍失败、不发消息；板子照常录完一轮（不再被使用）。

## 4. 证据

见 PR。

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知 |
| --- | --- | --- | --- |
| 1 | Claude | 初版 | iOS |
