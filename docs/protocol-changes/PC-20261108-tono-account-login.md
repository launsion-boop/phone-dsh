# tono-account user login for the phoneDSH cloud service

```yaml
change: PC-20261108-tono-account-login
contracts: [P05, P09, P18]
status: frozen
breaking: false
version_decision: No version change on any existing boundary. The gateway schema, /v1/http envelope, Worker variables, provider documents and error codes are unchanged. The session record is a new private secret item with its own version field (1).
base: 1b4fa4cd
contract_revision: spec/v1/golden/tono-account/cases.json@sha256:c15931d7eb88fa1487ec2f3db24dff23f0db7344e646b0bdf20f4819017e04e5
```

## 1. Trigger and roles

- Trigger: the cloud team's 2026-11-04 update recommends a per-user tono-account access token
  (client `phone-dsh-ios`) instead of the shared `pdsk_` API key. The token lives 2 h; a pasted
  token stops working after that.
- Current: iOS and Android can only paste a key for the model profile and the independent search.
  No host signs in, refreshes, or reacts to 401 `credential_expired` / 503 `identity_unavailable`.
- Expected: both hosts sign in with an SMS code, keep the refresh token in the platform secret
  store and the access token in memory, inject the token at the native gateway only for the cloud
  origin, rotate the refresh token atomically and single-flight, refresh-and-retry once on
  `credential_expired`, wait and retry on `identity_unavailable`, and sign out.
- Roles: coordinator / contract owner, iOS implementer, Android implementer and reviewer are one
  agent in this task, producing each role's output.
- Owning clause: [spec/v1/tono-account.md](../../spec/v1/tono-account.md). Shared fixture:
  [golden/tono-account/cases.json](../../spec/v1/golden/tono-account/cases.json). Registered
  under P05 and P18 in [spec/README.md](../../spec/README.md); open upstream details are GAP-34.
- Ends:
  - Producer (not in this repository): tono-account `account.tonoai.cn`, phoneDSH cloud
    `pdsh.tonoai.cn`.
  - Swift: `Sources/PhoneDSH/TonoAccount/**` (client, session, store), the two routers in
    `Sources/PhoneDSH/Phone{ModelProvider,WebSearch}Settings.swift`, `Sources/PhoneDSHGateway`
    (§5 policy and re-send), probe app wiring and page.
  - Kotlin: `android/net/src/main/kotlin/com/phonedsh/account/**`, `android/net` gateway
    (`GatewayCredential`, `ModelGatewayCredentialProvider`, `LoopbackModelProxy`,
    `IndependentSearchWebTools`), `android/app` wiring, `android/lib` page.
  - TypeScript Worker, Rust, Harmony: not changed (the Worker keeps its placeholders; Harmony does
    not publish the cloud model).

## 2. Delta

| Item | Before → after |
| --- | --- |
| Credential | pasted API key only → while signed in, the access token for the cloud origin's model paths and independent Search/Fetch, same header as the key; signed out unchanged (§4) |
| Account calls | none → send code, sign in, refresh (form), sign out, all to `https://account.tonoai.cn`, `client_id=phone-dsh-ios` on both platforms (§2) |
| Persistence | none → one secret item `{version:1, refresh_token, login_at_ms, user_id, phone_hint}`; iOS Keychain `dev.phone-dsh.tono-account`/`session`, Android `SecureStore` `tono-account.session`; access token memory-only (§3) |
| Rotation | — → one atomic item write before the new access token is published; single flight; generation guard against a late refresh after sign-in/out (§3) |
| Session end | — → 2xx-invalid/400/401/403 refresh answer or 180 days since sign-in ends the session with a visible notice; `transient` never ends it (§2, §3) |
| Gateway 401 | forwarded → cloud-origin `credential_expired`: invalidate, re-resolve, re-send once only when the value changed (§5) |
| Gateway 503 | backoff only for replay-safe requests → cloud-origin `identity_unavailable`: wait Retry-After (default 1 s, cap 30 s), at most two re-sends, any method (§5, §6) |
| Provider seam | iOS `CredentialProvider.invalidate` was a no-op in the model/search routers → forwards to the token source; Kotlin `GatewayCredentialProvider` and `ModelKeySource` gain a default no-op `invalidate` |
| P09 | — → page 「Tono 账号」 (`TonoAccountPage`) linked from 「模型与智能体」 next to 「模型服务」 on iOS and Android, generated contract `spec/ui/v1/pages/tono-account.json` |

Self-check (AGENTS §2): no second envelope, alias or error code; the cloud's existing codes are
consumed, not redefined. No new Worker variable, wire field or capability. New public Swift API
(token source, session) and new Kotlin `invalidate` defaults are additive. The gateway re-send is
limited to one origin and two codes defined by the cloud contract.

## 3. Compatibility

| Producer → consumer | Behaviour |
| --- | --- |
| Old app → cloud | Unchanged: the API key path. |
| New app, signed out → cloud | Unchanged: the API key path, byte-identical requests. |
| New app, signed in → cloud | User token on the same header; the cloud classifies it by prefix. |
| New app → other model/search origins | Unchanged: the token is never released there and §5 does not apply. |
| Worker (any version) | Unchanged: placeholders only; requests go through the host gateway/loopback edge already. |
| Stored data → rollback | An older app ignores the new secret item and keeps using the pasted key. Re-upgrading reads the item again (its refresh token may have expired in between → `session_ended`). |
| Unknown future record version → this app | Unreadable: signed out, item kept until sign-in or sign-out. |
| iOS ↔ Android | No shared data; both implement the same clause and read the same cases. |
| Harmony | Not started; it neither signs in nor publishes the cloud model. |

## 4. Ownership and acceptance

- Contract owner: `spec/**`, this record, `spec/tools/{registry_build,cross_check}.py`.
- iOS implementer: `Sources/PhoneDSH/TonoAccount/**`, the two router files, `Sources/PhoneDSHGateway/**`,
  `examples/probe-app/**` wiring and page, `Tests/PhoneDSH{,Gateway}Tests/Tono*`.
  Acceptance: `swift test --filter 'Tono|ModelGatewayTests|ModelProviderSettings|WebSearch'`.
- Android implementer: `android/net/**/account/**`, the listed `android/net` gateway files,
  `android/app` wiring, `android/lib` page and their tests.
  Acceptance (galic): `./gradlew --no-daemon :net:test :lib:testDebugUnitTest :app:testDebugUnitTest :app:assembleDebug`.
- Both ends read `cases.json` with their real parser/classifier and drive their real gateway with
  a local fake upstream (`retry_flows`).
- Shared: `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
- Not covered by automation: the real account service (sends real SMS), a physical phone,
  process death between rotation and the store write, model E2E.

## 5. Revisions

| Revision | Change |
| --- | --- |
| cases.json@sha256:c15931d7 | Frozen clause, constants, phone/code normalization, request encodings, response/outcome classes, record, clock, cloud-response and retry-flow cases. |

## 6. Verification

Filled in by the implementers and reviewer at the head of the change.
