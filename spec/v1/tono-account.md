# tono-account user credential for the phoneDSH cloud service

Status: normative for the iOS and Android hosts (`partial` until each end has runtime
evidence, see the change record). Change record:
[PC-20261108-tono-account-login](../../docs/protocol-changes/PC-20261108-tono-account-login.md).
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
