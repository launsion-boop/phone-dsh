# tono-account user credential for the phoneDSH cloud service

Status: normative for the iOS and Android hosts (`partial` until each end has runtime
evidence, see the change record). Change record:
[PC-20261108-tono-account-login](../../docs/protocol-changes/PC-20261108-tono-account-login.md); wallet and credits (§10–§11):
[PC-20261121-cloud-wallet-credits](../../docs/protocol-changes/PC-20261121-cloud-wallet-credits.md).
Shared cases: [golden/tono-account/cases.json](golden/tono-account/cases.json) — the cases are
the judge wherever this text and a case could be read two ways.

The phoneDSH cloud service (`https://pdsh.tonoai.cn`) accepts two credentials on the same
headers: an API key (`pdsk_…`, already supported by the model and independent-search
settings) and a per-user access token issued by tono-account to client `phone-dsh-ios`. The
cloud classifies a credential by its prefix: `pdsk_` is an API key, anything else a user token.
This clause adds the user token. It changes no Worker variable, no `/v1/http` envelope, no
gateway schema field and no error code. The Worker only ever sees the existing placeholders.

Upstream sources: the cloud team's "Phone DSH 云端对接说明" (2026-11-04 update, §2 用户登录,
§7 错误和重试). The account service's own `docs/MVP-API.md` is not available to this repository;
every member this clause reads beyond that document is listed in §2 and is a requirement on the
consumer side only (§9 lists what is still unconfirmed).

## 1. Constants

`constants` in the cases is the single list. In particular:

| Name | Value |
| --- | --- |
| Account origin | `https://account.tonoai.cn` |
| Cloud origin | `https://pdsh.tonoai.cn` — scheme `https`, host `pdsh.tonoai.cn`, effective port 443 |
| `client_id` | `phone-dsh-ios`, on iOS **and** Android (the cloud accepts only tokens issued to it; another client's token is answered 403) |
| OTP grant | `urn:tono:params:oauth:grant-type:phone-otp` |
| Default access lifetime | 7200 s when the token response has no `expires_in` |
| Refresh skew | `min(300 s, expires_in / 2)` |
| Re-verification | 180 days (15 552 000 s) after `login_at` |

## 2. Account-service exchanges

All requests carry `Accept: application/json`, never `x-api-key`, never a cloud credential, and
follow no redirect (a 3xx is a `transient` failure). Bodies and headers are pinned by
`requests`.

1. **Send code.** `POST /v1/auth/otp/send`, JSON `{"phone", "purpose":"login", "client_id"}`.
   `phone` is canonical (`phones`): ASCII spaces, `-` and line breaks are removed; the rest is
   either 11 ASCII digits starting with `1` (prefixed with `+86`) or `+86` followed by such 11
   digits. Anything else — other country codes, full-width digits, other separators — is refused
   before any request. A 2xx answer must be a JSON object with a non-empty string
   `challenge_id`. Outcomes: `otp_outcomes`.
2. **Sign in.** `POST /v1/oauth/token`, JSON `{"grant_type", "client_id", "phone", "challenge_id",
   "code", "device_info":{"platform","device_name","app_version","os_version"}}`. `platform` is
   `ios` or `android`. `code` is 4–8 ASCII digits after trimming (`codes`). Outcomes:
   `login_outcomes`.
3. **Refresh.** `POST /v1/oauth/token`, `application/x-www-form-urlencoded`,
   `grant_type=refresh_token&client_id=phone-dsh-ios&refresh_token=<value>` in this order. Values
   are percent-encoded: `A-Z a-z 0-9 - . _ ~` are kept, every other byte of the UTF-8 encoding is
   `%XX` with uppercase hex. Outcomes: `refresh_outcomes`.
4. **Sign out.** `POST https://account.tonoai.cn/v1/auth/logout` with
   `Authorization: Bearer <access token>` and an empty body.

**Token response** (`token_responses`). A 2xx JSON object with:

- `access_token`, `refresh_token`: non-empty strings of at most 4096 visible ASCII characters
  (`!`…`~`, no space or control). An `access_token` starting with `pdsk_` is invalid: the cloud
  would classify it as an API key.
- `expires_in`: optional; when present a JSON integer ≥ 1 (a fraction or string is invalid).
- `token_type`: optional; when present `Bearer`, compared case-insensitively.
- `user`: optional object. `user.id` is kept only when it is a string. `user.phone` yields a
  `phone_hint` of its last four characters only when they are four ASCII digits.
- Unknown members are ignored.

**Outcome classes.**

| Exchange | Answer | Outcome |
| --- | --- | --- |
| send code / sign in | 2xx valid | `challenge` / `signed_in` |
| send code / sign in | 2xx invalid | `protocol_error` (nothing stored) |
| send code | 400, 401, 403 | `rejected` |
| sign in | 400, 401 | `invalid_code` |
| sign in | 403 | `rejected` |
| any | 429 | `rate_limited`, `retry_after_seconds` from §6 parsing or `null` (refresh: `transient`) |
| refresh | 2xx valid | `rotated` |
| refresh | 2xx invalid, 400, 401, 403 | `session_ended` |
| any | other status, 3xx, transport error | `transient` |

`session_ended` is the only refresh outcome that ends a session. A reused refresh token (the
account service revokes the whole session), an expired 30-day refresh token, a revoked session and
the server-side 180-day limit all arrive as 400/401 and are not told apart: each is a forced
re-login. `transient` (including 503 `identity_unavailable` from the account service) never ends
a session and never asks the person to sign in again.

## 3. Session state and persistence (P18)

The host keeps one session per app install. The **refresh token** and session facts are stored in
one platform secret item; the **access token** lives only in process memory.

- iOS: Keychain generic password, service `dev.phone-dsh.tono-account`, account `session`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Android: the platform `SecureStore` key `tono-account.session` (Keystore envelope).

The stored value is UTF-8 JSON (`session_records`):
`{"version":1, "refresh_token", "login_at_ms", "user_id"|null, "phone_hint"|null}`. `version`
must be the integer 1, `refresh_token` valid per §2, `login_at_ms` a non-negative integer
(milliseconds since the Unix epoch of the successful OTP sign-in; a refresh never changes it).
Unknown members are ignored. Any other value is **unreadable**: the host behaves as signed out,
does not delete the item, and overwrites it only on the next successful sign-in or deletes it on
sign-out.

**Atomic replacement.** The stored value is always replaced as one write of the one item
(`SecItemUpdate`/`SecItemAdd` of the same item; one `SecureStore.put`). There is never a moment
where two refresh tokens are stored or where the item is deleted and re-added. Order for a
`rotated` answer: (1) write the new record; (2) only then publish the new access token. If the
write fails, the new refresh token is kept in memory (the old one is already invalid on the
server and is never sent again), the access token is still used, and the write is retried before
the next refresh. A process exit between the server's rotation and a successful write leaves the
old token on disk; its next use ends the session (`session_ended`). This is accepted and visible,
never silent.

**Single flight.** At most one refresh request is in flight per process. Every caller that needs
an access token while a refresh is running awaits that refresh's result. A refresh token value is
sent at most once on success paths; after a `transient` failure it may be sent again (if the
server had rotated without the answer arriving, that reuse ends the session — also accepted).

**Generation.** Sign-in and sign-out start a new session generation. A refresh that completes for
an older generation is discarded: it neither writes the store nor publishes a token.

**Clock** (`clock`). For a session with `login_at_ms` L and an access token issued at I with
lifetime E, at time N: if `N − L ≥ 180 days` the session ends with `reverify_required` (store
deleted, no request). Otherwise the cached access token is used while `I ≤ N < I + E − skew`,
and refreshed otherwise (a clock that runs behind I also refreshes). A session restored from the
store has no access token and refreshes before first use.

**Observable states** (P09): `signed_out`; `signed_in {phone_hint, reverify_at}`; and a one-shot
notice after an automatic end: `session_ended` (「登录已失效，请重新登录」) or
`reverify_required` (「登录已满 180 天，请重新验证手机号」). The UI never shows a token.

**Sign out.** If an unexpired access token is in memory, send §2.4 once, best effort (bounded
timeout, outcome ignored). Independently of that answer, delete the store item, drop the
memory copies and start a new generation. Sign-out succeeds offline.

## 4. Credential precedence at the gateway (P05)

While a session is signed in, the access token replaces the API key for exactly the requests the
existing routers would have given the API key **and** whose origin is the cloud origin (§1):

- model-protocol paths of the selected model profile when its endpoint origin is the cloud origin
  (header unchanged from that platform's API-key path: iOS `x-api-key`, Android
  `Authorization: Bearer`; the cloud accepts either for models);
- the independent Search/Fetch operations when the independent base's origin is the cloud origin
  (header unchanged: `Authorization: Bearer`).

The router's own origin and path admission is unchanged and decides first; the token never goes to
another origin, path or port. While signed in, the stored API key for those routes is not used,
including when the token cannot be obtained: a `transient` refresh failure fails the request
`credential_unavailable` before any upstream contact. A missing API key does not disable those
routes while signed in (iOS and Android launch the independent search with the cloud base even
without a stored search key). Signed out (never signed in, signed out, or ended) the existing API
key path applies unchanged. Only one credential header is sent (no `credential_conflict`).
Cloud speech (ASR/TTS for the TonoLink voice turn) follows the same precedence; its
signed-out fallback is defined in [cloud-voice.md](cloud-voice.md) §1.

## 5. Upstream answers from the cloud origin (P05)

For a request to the cloud origin (exact scheme, host and effective port) the host inspects a
401 or 503 answer **before** anything of it is forwarded, reading at most 16 384 body bytes.
`cloud_responses` is the judge:

- **401 `credential_expired`.** The body is a JSON object whose `error` member is an object with
  `code` or `type` equal to `credential_expired`. The host calls the credential provider's
  `invalidate` for the injected value, resolves the credential again, and re-sends the same method,
  URL and body once **only if** the new value differs (an API key, an unchanged value or a failed
  resolution forwards the original 401). The re-send is allowed for any method because the cloud
  rejected the request before any model work. At most one such re-send per request.
- **503 `identity_unavailable`** (same `code`/`type` rule). The host waits per §6 and re-sends;
  at most two such re-sends per request; then the last 503 is forwarded. Credentials are not
  invalidated and the session is never ended.
- Everything else — other 401 codes (`credential_revoked`, invalid key), 403 (account disabled or
  another app's token), a body over the limit, a non-JSON body, another origin — is forwarded under
  the existing failure surface with no automatic retry. A forwarded body is byte-identical to what
  the upstream sent.

`retry_flows` pins the combined counters (`contacts`, `invalidations`, `sleeps_seconds`). These
re-sends are separate from, and do not consume, the gateway's existing 429/5xx backoff for
replay-safe requests.

## 6. Retry-After

`Retry-After` is read as a non-negative ASCII decimal integer of seconds. Absent, empty, negative,
fractional or non-numeric (including an HTTP date) yields the default of 1 s. The delay is capped
at 30 s.

## 7. Secrets

The access token, refresh token, OTP code and full phone number never appear in logs, metrics,
diagnostics, error messages, `toString()`/`description`, the Worker environment, the UI, the
response log or a crash report. The phone number is held only while the sign-in page needs it.
Response redaction treats the access token exactly like an injected API key.

## 8. Tests

Automated tests use a local fake of the account service and the cloud; they never contact
`account.tonoai.cn` (it sends real SMS) and use only the synthetic values in the cases. Each end
reads `cases.json` with its real parser, classifier and gateway code.

## 9. Unconfirmed upstream details

Recorded as GAP-34 in the baseline. Until the account service's `MVP-API.md` §3, §4.1, §4.9, §5.1
are checked against §2, these consumer rules stand: response members beyond `access_token`,
`refresh_token`, `expires_in`, `token_type`, `user.id`, `user.phone`; the 400/401/403 split of the
token endpoint; whether model endpoints spell `credential_expired` in `error.code` or
`error.type` (both are accepted); whether Android should get its own `client_id`.

## 10. Wallet and claim (P05, P09)

Change record: [PC-20261121-cloud-wallet-credits](../../docs/protocol-changes/PC-20261121-cloud-wallet-credits.md).
Upstream source: the cloud team's "Phone DSH 云端对接说明" (2026-11-19 update, §4 积分和领取, §9).
Both endpoints answer 404 until the cloud's next release; the host treats that as
`unavailable` and shows nothing.

Credits are carried as **micro-credits**: 1 credit = 1 000 000 micro-credits, as a JSON string of
1–30 ASCII digits (`0`–`9`; no sign, point, exponent or full-width digit). Leading zeros are
allowed and ignored.

1. **Read.** `GET <cloud origin>/v1/wallet`, `Authorization: Bearer <access token>`,
   `Accept: application/json`, no body, no redirect followed. Only while signed in (§3); the host
   never reads or claims with an API key. Outcomes: `wallet_responses`.
2. **Claim.** `POST <cloud origin>/v1/wallet/claim`, same headers, empty body. The cloud grants at
   most once per account and answers every repeat with 200 and `granted_now: false`; that is a
   success, never an error. At most one claim is in flight per process (the control is disabled
   while it runs); a failed claim is re-sent only when the person taps again. Outcomes:
   `claim_responses`.

**Wallet object.** A JSON object with `available_micro_credits` (micro-credit string, required) and
`claimable` (JSON boolean, required). `mode`, when present, must be a string and is kept as-is
(`shadow`, `live`, or a future value); it is informational only. Every other member
(`reserved_micro_credits`, `granted_micro_credits`, `spent_micro_credits`,
`shadow_spent_micro_credits`, unknown members) is ignored, whatever its shape. A claim answer is a
JSON object with `granted_now` (JSON boolean) and `wallet` (a valid wallet object).

| Answer (read or claim) | Outcome |
| --- | --- |
| 2xx valid | `wallet` / `claimed {granted_now, wallet}` |
| 2xx invalid (not JSON, not an object, a required member missing or of the wrong type) | `protocol_error` |
| 401 | §5 applies first (`credential_expired` → refresh and re-send once); what remains is `unauthorized` |
| 403 (API key → `credential_not_allowed`, another app's token, disabled account) | `rejected` |
| 404 | `unavailable` |
| 3xx, 429, other status, transport error | `transient` |

**Display.** The host shows `available_micro_credits` ÷ 1 000 000, truncated (never rounded up)
to two decimals, trailing zeros and a trailing point removed, ASCII digits, no grouping
(`credit_display`). The 「领取积分」 control is shown exactly when the last `wallet` outcome had
`claimable: true`. After `claimed` the host shows the returned wallet. The wallet is read when the
account page or the credits notice (§11) appears and after every claim; it is not polled. Signing
out drops the cached wallet. A wallet value never appears in logs beyond the outcome name.

## 11. Credits answers (402) from the cloud origin (P05, P09)

When the cloud wallet is `live`, a model (Anthropic or OpenAI format), Search/Fetch, TTS request or
ASR handshake from an account with no claim or no credits is answered 402. For a request to the
cloud origin (§5's exact origin rule) the host reads at most 16 384 body bytes of a 402 and
classifies it (`credits_responses`):

- `error` is an object whose `code` is the string `credits_not_claimed` → `not_claimed`;
- … `insufficient_credits` → `insufficient`;
- any other 402 from the cloud origin — `error.type: billing_error` without a known `code`, a code
  only in `type` or `message`, a non-JSON or empty body, a body over the limit, or an ASR handshake
  whose body the platform does not expose — → `unspecified`;
- not 402, or another origin → no credits condition (existing rules only).

Rules for every credits condition:

1. **No retry.** The host never re-sends the request (not in §5's counters, not in the gateway's
   429/5xx backoff, not in the voice client). A gateway-forwarded answer stays byte-identical, so
   DSH shows its own error for that turn.
2. **One notice.** The host raises one observable credits notice (P09) and re-reads the wallet
   (§10.1). The guidance (`credits_guidance`) is `claim` for `not_claimed`; `exhausted` for
   `insufficient`; for `unspecified` it follows the re-read wallet: `claimable: true` → `claim`,
   `false` → `exhausted`, no `wallet` outcome → `unknown`.
3. **Texts.** `claim`: 「还没有领取积分，领取后即可继续使用」 with the 「领取积分」 control.
   `exhausted`: 「积分已用完」 and no retry control. `unknown`: 「云端服务需要积分，请在 Tono 账号中查看」.
   A notice raised while the same guidance is already shown replaces it; it is dismissed by the
   person, by a successful claim, or by signing out.
4. A voice turn that ends in a credits condition fails like any other failed turn
   ([cloud-voice.md](cloud-voice.md) §1); it does not claim on the person's behalf.

Signed out with an API key, the cloud wallet is in `shadow` and the cloud does not answer 402; if it
ever does, the same classification and notice apply, without a claim control (claiming needs a
signed-in session, §10).
