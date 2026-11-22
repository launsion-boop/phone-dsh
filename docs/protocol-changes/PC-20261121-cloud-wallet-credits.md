# Cloud wallet, claim and credits answers (402)

```yaml
change: PC-20261121-cloud-wallet-credits
contracts: [P05, P09]
status: partial
breaking: false
version_decision: No version change. Two new consumer exchanges on the existing cloud origin (GET /v1/wallet, POST /v1/wallet/claim) and a classification of an existing status (402). No Worker variable, wire field, envelope, header or error code is added; the 402 body reaches DSH unchanged on iOS and under Android's existing non-2xx surface.
base: 7ad45d3bf79ef243408a7532265e1b47fc943861
contract_revision: spec/v1/golden/tono-account/cases.json@sha256:fc9558d65ab71c35f9d2b1a0bbfd601ece6d1147c20a17018406f9a6e79014c3
```

## 1. Trigger and roles

- Trigger: the cloud team's "Phone DSH 云端对接说明" (2026-11-19 update). The cloud's next release
  meters model, ASR, TTS and Search/Fetch in credits. Phase 1 (`shadow`) blocks nothing and
  changes nothing for the shipped 0.1.0 app. Phase 2 (`live`) answers 402 to an account that has
  not claimed, or has no credits left. The app that ships before phase 2 must offer 「领取积分」,
  show the balance and handle both 402 codes.
- Current: no host reads a wallet, claims, or recognises 402. A 402 from the cloud reaches DSH as
  an opaque failure; the person cannot tell what to do.
- Expected: signed in, both hosts read the wallet, show 剩余积分 and, while `claimable`, a
  「领取积分」 control; a cloud-origin 402 is never re-sent and raises one notice: claim, used up,
  or (body unknown) whatever the re-read wallet says.
- Roles: coordinator / contract owner, iOS implementer, Android implementer and reviewer are one
  agent in this task, producing each role's output.
- Owning clause: [spec/v1/tono-account.md](../../spec/v1/tono-account.md) §10–§11, plus one
  paragraph in [cloud-voice.md](../../spec/v1/cloud-voice.md) §1. Shared fixture:
  [golden/tono-account/cases.json](../../spec/v1/golden/tono-account/cases.json), new keys
  `wallet_responses`, `claim_responses`, `credit_display`, `credits_responses`,
  `credits_guidance` and four constants. Existing keys are byte-identical.
- Ends:
  - Producer (not in this repository): phoneDSH cloud `pdsh.tonoai.cn` (`/v1/wallet`,
    `/v1/wallet/claim`, 402 on model/ASR/TTS/Search).
  - Swift: `Sources/PhoneDSHGateway/{TonoCloudResponsePolicy,ModelGateway}.swift` (402
    classification and the one-shot handler), `Sources/PhoneDSH/TonoAccount/TonoCloudWallet.swift`
    (wallet protocol, client, `TonoCloudCreditsSignal`), `Sources/PhoneDSH/PhoneDSHHost.swift`
    (wires the gateway handler to the signal), `Sources/PhoneDSH/CloudVoice/CloudVoiceClients.swift`
    (ASR handshake 402, TTS 402); probe app `CloudCreditsCenter.swift`, `CloudCreditsBanner.swift`,
    `TonoAccountPage.swift` (new 积分 section; its page contract regenerated), `NativeShell.swift` and `Bot/BotChatPage.swift` (one same-line modifier each, so the line pointers in `spec/ui/v1/tokens.json` and the page contracts do not move).
  - Kotlin: `android/net` `gateway/TonoCloudResponsePolicy.kt`, `gateway/GatewaySession.kt`,
    `loopback/LoopbackModelProxy.kt`, `account/TonoCloudWallet.kt`, `account/TonoAccountSession.kt`
    (the transport no longer opens a body for GET); `android/lib` `TonoAccountPage.kt`,
    `UiPageTags.kt`, `PdshNavFacts.kt`, `PdshNavHost.kt`; `android/app` `TonoAccountHost.kt`,
    `HostShell.kt`.
  - TypeScript Worker, Rust, Harmony: not changed. The Worker and DSH see the same answers as
    before. Harmony does not publish the cloud model.

## 2. Delta

| Item | Before → after |
| --- | --- |
| Wallet read | none → `GET /v1/wallet`, Bearer user token, signed in only; outcomes `wallet` / `protocol_error` / `unauthorized` / `rejected` / `unavailable` (404, before release) / `transient` (§10) |
| Claim | none → `POST /v1/wallet/claim`, empty body, single flight, re-sent only on another tap; `granted_now: false` is success (§10) |
| Wallet object | — → required `available_micro_credits` (1–30 ASCII digits) and `claimable` (JSON boolean); optional string `mode`; every other member ignored |
| Display | — → micro-credits ÷ 1 000 000 truncated to two decimals, no grouping (`credit_display`) |
| Cloud 402 | opaque failure → classified `not_claimed` / `insufficient` / `unspecified` from `error.code` only, ≤ 16 384 bytes; other origins untouched (§11) |
| Re-send | — → a 402 is never re-sent (outside §5's counters and the 429/5xx backoff; voice turn fails) |
| Notice (P09) | — → one notice: `claim` 「还没有领取积分，领取后即可继续使用」 with 「领取积分」, `exhausted` 「积分已用完」 with no retry, `unknown` 「云端服务需要积分，请在 Tono 账号中查看」; `unspecified` follows the re-read wallet |
| Tono 账号 page (P09) | — → section 「积分」 while signed in: 剩余积分, 「领取积分」 while `claimable`, footer; hidden after a 404 |
| ASR handshake | 401 only → 402 is a credits answer; iOS does not expose the handshake body, so it is `unspecified` |

Self-check (AGENTS §2): one authority (§10–§11 of the existing owning clause, cases in the
existing golden). No second envelope or alias: the cloud's two codes are consumed, not renamed;
`unspecified` is a local classification, never sent. No contract loosened: no existing case,
check or fixture changed. No Worker-visible change.

## 3. Compatibility

| Pair | Result |
| --- | --- |
| old app → new cloud (`shadow`) | unchanged: no 402 is sent in `shadow` |
| old app → new cloud (`live`) | 402 shown by DSH as an opaque error; the person cannot claim. This is why the cloud switches to `live` only after most users run the new app (cloud's own plan) |
| new app → old cloud (today, before release) | `/v1/wallet` answers 404 → `unavailable`: the 积分 section stays hidden, nothing else changes |
| new app → new cloud | full behaviour |
| old data → new | no persisted state is added; the wallet is memory-only and dropped on sign-out |
| rollback | removing the code removes the section and the notice; no data to migrate |

## 4. Gap list per handoff item

| # | Handoff item | Status | Notes |
| --- | --- | --- | --- |
| 1 | 「领取积分」 on `claimable`, claim idempotent, user token only | implemented (iOS, Android) | Signed out: no request at all, so an API key never reaches `/v1/wallet*` |
| 2 | Show remaining credits | implemented (iOS, Android) | Truncated to 2 decimals so the shown balance never exceeds the real one |
| 3 | Two 402s on model / ASR / TTS / search | iOS: model, search, ASR handshake, TTS. Android: model (loopback proxy) and independent search (GatewaySession) | Android has no ASR/TTS consumer (cloud-voice.md is iOS-only). Android's model proxy already replaces every non-2xx body with its own `upstream_status` body (existing P05 behaviour, not changed here); DSH on Android sees a generic error, the notice carries the guidance |
| 4 | Drop `deepseek-v4-pro` | no code change needed | No default, profile seed, request path or Worker setting names it; every default is `deepseek-flash`. It appears only in the Bot model-purpose tier classifier (`BotModelPurposePolicy.largeModel`/`LARGE_MODEL`, `validate_vectors.py`, `export-vectors.mjs`) and its golden as a model that small purposes must refuse; that stays correct after withdrawal. Changing it would alter four mirrors for no observable effect. Residual: a person who typed `deepseek-v4-pro` into a profile gets 400 after release; see GAP below |
| 5 | No shared `pdsk_` key in the package | verified | `git grep` for `pdsk_[A-Za-z0-9_-]{20,}` finds none in sources, bundles, plists or Gradle files; `TonoAccountProtocol` only rejects the prefix |
| 6 | `/v1/prices` | not started (optional) | Not needed for phase 2; can follow without a contract change to §10–§11 |

## 5. Not verified

- No request reached `pdsh.tonoai.cn`; the wallet endpoints answer 404 until the cloud release.
- No device run. The iOS app compiled for the simulator SDK; no UI test drove the new section.
- Whether a URLSession WebSocket handshake 402 is surfaced as `task.response` status on device.
- Whether DSH's error text for an iOS 402 is readable (DSH renders the cloud body).

## 6. Open risk

- Saved model name `deepseek-v4-pro` on the cloud origin → 400 after release. Options: leave it
  (the person can pick another model), or a P18 migration that rewrites it to `deepseek-flash`
  for cloud-origin profiles. Needs a decision; not done here.
