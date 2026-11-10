# Cloud speech for a voice turn (ASR and TTS client)

Status: `partial` (iOS consumer only, until device evidence). Owner: P05. Change record:
[PC-20261110-tonolink-voice-turn](../../docs/protocol-changes/PC-20261110-tonolink-voice-turn.md).
Shared cases: [golden/cloud-voice/cases.json](golden/cloud-voice/cases.json), the judge where this
text could be read two ways.

The producer is the phoneDSH cloud service at the cloud origin (tono-account.md §1). Its contract
lives outside this repository: `TonoTeam/phone-dsh-cloud` `contracts/asr-protocol.md` (pdsh-asr.v1,
v0.2 baseline), `contracts/asr-messages.schema.json` and `contracts/openapi.yaml` `/v1/tts/speech`,
at commit `64a3d2098ca2`, plus the cloud team's 2026-11-04 integration note. This clause is the
**consumer subset** the phone uses; it adds no field, message or code to that contract. The
consumer is `Sources/PhoneDSH/CloudVoice/**`; the caller is the TonoLink voice turn
([tonolink-board.md](../device/v1/tonolink-board.md) §4.1). Android and HarmonyOS have no consumer.

## 1. Credential

Exactly one value, sent as `Authorization: Bearer <value>`, and only to the cloud origin (scheme
`https`, host `pdsh.tonoai.cn`, effective port 443):

1. Signed in (tono-account.md §3): the access token. If it cannot be obtained the turn fails
   before any request; the API key is **not** used instead (same rule as tono-account.md §4).
2. Signed out: the API key of the selected model profile, only when that profile's endpoint origin
   is exactly the cloud origin. Any other origin, or no key: voice is unavailable and nothing is sent.

A TTS `401` whose JSON `error.code`/`error.type` is `credential_expired`, or an ASR handshake answered
`401`, invalidates the injected value once (tono-account.md §5); the request is re-sent once only if
the newly resolved value differs. Every other status is reported as the turn's failure without retry.

## 2. Recognition (`wss://pdsh.tonoai.cn/v1/asr/stream`)

- Sub-protocol `pdsh-asr.v1`. First text message, exactly the `start` in the cases (`interactive`,
  `zh`, Opus 16 kHz mono `frame_ms` 20, `single_utterance` true, hotwords 小智 and 托诺,
  `client_ref` `tonolink-<turn id>`).
- Each binary message is one Opus body from the board (§4.1), unchanged and in arrival order; the
  board produces them in real time. Bodies that arrive before `started` are queued, at most 100
  (2 s); one more fails the turn with `cancel`.
- When the board's audio ends (§4.1) the client sends `{"type":"finish"}` unless a terminal message
  already arrived. A user cancel or a new wake sends `{"type":"cancel"}`.
- Deadlines: the connection (TLS and upgrade) within 10 s; `started` within 5 s of `start` being
  written on the open connection (the cloud's own 5 s, not counting a slow network); a terminal within `started.limits.finish_timeout_ms`
  (15 000 if absent) + 5 000 ms of `finish`. A missed deadline cancels and fails the turn.
- Results: `partial` is display-only and never executed. The text of the turn is the `final` texts in
  `segment_id` order, joined without separator, **only** after `completed`. `completed` with
  `end_reason` `no_speech`, or an empty text, ends the turn silently. `cancelled`, `error`, a close
  without a terminal, or an unknown terminal shape fails the turn; no text is used, nothing is
  re-sent (the audio cannot be replayed). Unknown non-terminal `type`s are ignored.

## 3. Speech (`POST https://pdsh.tonoai.cn/v1/tts/speech`)

- Body `{"input": <text>, "voice": "zh-female-vv", "response_format": "pcm"}`; the answer is 16 kHz
  mono s16le, played as it streams (HTTP chunk boundaries are not sample boundaries).
- `input` is 1…1000 Unicode scalars. Reply text is first made speakable (the cases' `speakable`):
  fenced code blocks dropped, Markdown emphasis, headings, bullets, inline-code ticks and link
  targets removed, whitespace collapsed. It is then split at the last sentence end (`。！？；.!?;` or a
  line break) at or before 1000 scalars, else cut at 1000. Chunks are requested one at a time in
  order; at most the next one may be prefetched while the current one plays.
- A stream that fails after audio started is incomplete: playback of that reply stops there and the
  rest is not requested. Cancelling (new wake, stop) cancels the request and drops unplayed audio.
- The 「我在」 audio may be kept in memory for the life of the process and replayed.

## 4. The turn

The recognised text is sent as an ordinary user message to the current chat, through the same path
as the composer. What is spoken back is the last assistant text of that chat turn. A turn that is
still running in the chat when a new wake arrives keeps running; only its speech is stopped.
