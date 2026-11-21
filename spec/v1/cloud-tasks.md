# Phone task queue (cloud ↔ phone)

Revision `cloud-tasks-v1.7`, frozen 2026-11-21 (v1.1 rules three implementer change requests:
response openness, device takeover, terminal reason mapping; v1.2 makes the oracle and two new
cases agree that openness reaches nested `target` and `sealed`; v1.3 names the ack for sealed
bytes that open but are not a task text; v1.4 forbids swapping the key under one `key_id`; v1.5 removes a
self-contradictory empty-plaintext case and writes down the clock and re-send bounds; v1.6 lets a
background push request a wake lease from the host orchestrator
[host/v1/README.md §10.2](../host/v1/README.md) and leaves the payload, routes, ack and limits
byte-for-byte unchanged from v1.5; v1.7 adds the Android FCM transport). Each provider's
online delivery requires configuration and device evidence.
Owner: P05. Change record:
[PC-20261116-cloud-task-queue](../../docs/protocol-changes/PC-20261116-cloud-task-queue.md).
Shared cases: [golden/cloud-tasks/cases.json](golden/cloud-tasks/cases.json), the judge where this
text could be read two ways. Reference oracle: `spec/v1/tools/test_cloud_tasks.py`.

Another client signed in to the same tono account leaves a task for one phone. The cloud keeps
it durably until that phone confirms it wrote the task into its own admission journal
([external-admission.md](../host/v1/external-admission.md)). The phone runs the task; the cloud
never does. This is the producer **and** consumer contract: the cloud service
(`TonoTeam/phone-dsh-cloud`) imports this file and the cases as a whole package under
`contracts/phone-tasks/v1/` (flat: this file, `cases.json`, the oracle; the oracle reads its cases
from `PDSH_CLOUD_TASK_CASES` when set; links in this file resolve only in the source repository)
and does not edit them.

## 1. Boundaries

- The cloud stores **no readable task content**. The task text is sealed to a public key that the
  phone registered; the cloud stores and forwards the ciphertext and deletes it when the task
  leaves `pending`. The cloud never holds a private key.
- Sealing gives confidentiality against the cloud's storage. It does **not** authenticate the
  submitter to the phone: the phone trusts the cloud's account check for that, exactly as it does
  for model traffic. A fetched task is therefore an ordinary request attributed to
  `account:<user id>`; it carries no approval and bypasses no permission prompt on the phone.
- A push notification carries no task id, target or content and grants nothing. Losing every push
  loses no task.
- Origin: the cloud origin of tono-account.md §1 (`https://pdsh.tonoai.cn`). Credential:
  `Authorization: Bearer <tono access token>` only; an API key (`pdsk_…`) is answered `403
  credential_not_allowed` on every route here. Refresh and re-send follow tono-account.md §5.
- Routes are add-only under `/v1/phone/**`. Every JSON **request** body is a closed object: an
  unknown member is `400 invalid_request`. Every response carries `server_time_ms`. **Responses
  are open**: the receiver ignores members it does not know, at every level, and still requires
  the members named here with the stated types.
- Opaque ids (`device_id`, `request_id`, `key_id`, target `id`) match `[A-Za-z0-9._:-]{1,128}`.
  `task_id` is chosen by the cloud and matches the same pattern. Another account's device or task
  is `404 not_found`, never `403`.
- Errors are `{"error":{"code":<code>,"message":<text>},"server_time_ms":<int>}` with the codes
  named below; the phone acts on `code` and the HTTP status only.

## 2. Device registration

`device_id` is `dev-` + a lowercase UUIDv4, generated once per install and stored under the
preference key `phone-dsh.bot.cloud.device-id.v1` (the same identity the Bot cloud scheduler
uses; one install has one cloud device id).

`PUT /v1/phone/devices/{device_id}`

```json
{"schema":"phone-device/v1","platform":"ios","app_version":"1.4.0",
 "key":{"key_id":"k-1","suite":"hpke-p256-sha256-aes128gcm","public_key":"<base64url, 65 bytes>"},
 "push":{"provider":"apns","environment":"production","topic":"com.tono.phonedsh","token":"<hex>"}}
```

- `platform`: `ios` | `android`. `push` is `null` when the phone has no usable token.
- For iOS the closed `apns` object above uses 64–200 lowercase hex characters for `token`.
  For Android the closed object is `{"provider":"fcm","token":"<opaque>"}`. FCM tokens contain
  1–4096 visible ASCII bytes (0x21 through 0x7e). Treat them as opaque credentials, never logs.
  Reject a provider for the other platform or additional members.
- A v1.7 Android phone receiving `400 invalid_request` for a registration with FCM may retry
  once without `push` for a v1.6 server, using the same device id and sealing key. Fallback
  applies only to that token until it rotates or the process restarts. The server rolls out first.
- `public_key` is an uncompressed P-256 point (`0x04 ‖ X ‖ Y`), base64url without padding.
- The call replaces the registration. Registering a different `key_id` makes tasks sealed to the
  old key undeliverable: the cloud marks each such `pending` task `rejected` / `key_replaced`.
- A `key_id` names one key. A `PUT` by the same account whose `key_id` equals the registered one
  but whose `public_key` differs is `409 key_mismatch` and changes nothing; rotation uses a new
  `key_id`. (A takeover compares nothing: the previous registration belonged to another account.)
  A phone that receives this answer creates a new key with a new `key_id` and registers again.
- At most 8 devices per account: `409 device_limit`.
- Takeover: a `PUT` for a `device_id` that is registered to **another** account moves the
  registration to the caller. The previous account's registration is removed and each of its
  `pending` tasks for that device becomes `cancelled` / `device_removed`; its tasks past
  `pending` are unchanged and can no longer be acknowledged (they reach `unknown` by the §6
  21-day rule). The response is the ordinary `200`. This is the one exception to the `404` rule
  of §1 and exists because an install has one device id across sign-outs.
- Response `200 {"schema":"phone-device-ack/v1","device_id","key_id","server_time_ms"}`.

`GET /v1/phone/devices` → `{"schema":"phone-device-list/v1","devices":[{"device_id","platform",
"key":{…},"updated_at_ms"}],"server_time_ms"}`. Push tokens are never returned.

`DELETE /v1/phone/devices/{device_id}` → `204`; every `pending` task of that device becomes
`cancelled` / `device_removed`. Repeating it is `204`. The phone calls it on sign-out.

## 3. Sealing

HPKE (RFC 9180) base mode, single shot, suite DHKEM(P-256, HKDF-SHA256) / HKDF-SHA256 /
AES-128-GCM (`kem_id 0x0010`, `kdf_id 0x0001`, `aead_id 0x0001`).

- Plaintext: the UTF-8 task text, 1–16384 bytes.
- `info` = the ASCII bytes `pdsh-phone-task/v1`.
- `aad` = UTF-8 of the seven lines `pdsh-phone-task/v1`, `device_id`, `key_id`, `request_id`,
  `target.kind`, `target.id`, decimal `expires_at_ms`, joined by single `\n` with no trailing
  newline. Changing any of them makes the task unopenable; the cloud cannot re-target a task.
- `sealed.enc` is the 65-byte encapsulated key, `sealed.ct` is ciphertext ‖ 16-byte tag, both
  base64url without padding.

The private key never leaves the phone: iOS Keychain item, service `dev.phone-dsh.cloud-tasks`,
account `<key_id>`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; Android a keystore-wrapped
record under `SecureStore` key `cloud-tasks.key.<key_id>`. The phone keeps the previous key until
no `pending` task names it.

## 4. Submit and status (submitter side)

`POST /v1/phone/tasks`

```json
{"schema":"phone-task-submit/v1","device_id":"dev-…","request_id":"req-1","key_id":"k-1",
 "target":{"kind":"dsh-session","id":"gb-main"},"expires_at_ms":1794786400000,
 "sealed":{"enc":"<base64url>","ct":"<base64url>"}}
```

- `target.kind`: `dsh-session` | `bot`. The cloud does not know whether the target exists.
- `expires_at_ms − server now` must be within 60 000 … 604 800 000 ms: else `400 invalid_expiry`.
- `sealed.ct` decodes to 17–16400 bytes, `sealed.enc` to 65 bytes: else `400 invalid_request`.
- Unknown device: `404 not_found`. `key_id` is not the device's current key: `409 key_mismatch`.
- 256 `pending` tasks already wait for the device: `429 queue_full`.
- Dedupe key `(account, device_id, request_id)`. A repeat whose remaining members are byte-equal
  is `200` with `duplicate: true` and the original `task_id`; any difference is
  `409 request_conflict`. The first accepted submit is `201` with `duplicate: false`.
- Response `{"schema":"phone-task-receipt/v1","task_id","state","duplicate","server_time_ms"}`.
  `201` means the cloud stored it durably — not that the phone has it.

`GET /v1/phone/tasks/{task_id}` → `{"schema":"phone-task-status/v1","task_id","device_id",
"request_id","state","reason"?,"created_at_ms","updated_at_ms","server_time_ms"}`.

`POST /v1/phone/tasks/{task_id}/cancel` → a `pending` task becomes `cancelled` / `submitter`
(`200`, status body). A task already past `pending` is `409 already_admitted`; cancelling a
`cancelled` task is `200`.

## 5. Pull and acknowledge (phone side)

`GET /v1/phone/tasks/pull?device_id=…&limit=…&lease_s=…&wait_s=…`

- `limit` 1–16 (default 16), `lease_s` 5–900 (default 300), `wait_s` 0–60 (default 0, long poll).
  Out-of-range values are clamped.
- Returns `pending`, unexpired tasks of that device whose lease is absent or expired, oldest
  first, and leases each one:

```json
{"schema":"phone-task-pull/v1","tasks":[{"task_id":"t-1","request_id":"req-1","key_id":"k-1",
  "target":{"kind":"dsh-session","id":"gb-main"},"expires_at_ms":1794786400000,
  "created_at_ms":1794700000000,"sealed":{"enc":"…","ct":"…"},
  "lease":{"lease_id":"l-1","attempt":1,"expires_at_ms":1794700300000}}],"server_time_ms":1794700000000}
```

A lease only spaces out redelivery; it is not an execution right.

A `tasks` element the phone cannot decode (a required member missing or of the wrong type or
form) does not fail the pull: when its `task_id` is a valid id the phone acks it `rejected` /
`invalid`, otherwise it is skipped without an ack. The other elements are processed normally.

`POST /v1/phone/tasks/ack`

```json
{"schema":"phone-task-ack/v1","device_id":"dev-…",
 "acks":[{"task_id":"t-1","state":"admitted","admission_id":"<64 hex>"},
         {"task_id":"t-2","state":"rejected","reason":"target_missing"}]}
```

1–16 acks. Response `{"schema":"phone-task-ack-result/v1","results":[{"task_id","accepted",
"duplicate","state"}],"server_time_ms"}` in request order; `state` is the task's state after the
call. A task of another device or account is `accepted: false`, `state: "not_found"`; so is
every ack while `device_id` is not registered to the caller (after its `DELETE` or a takeover).
The phone keeps such terminal acks and re-sends them after it registers again.

## 6. Task states

`pending → admitted → completed | failed | unknown`, and from `pending` also
`rejected | expired | cancelled`.

| Ack `state` | From | Required members | Meaning |
|---|---|---|---|
| `admitted` | `pending` | `admission_id` | the phone's admission journal durably holds the task; the cloud stops redelivering and deletes the ciphertext |
| `rejected` | `pending` | `reason`: `invalid` \| `conflict` \| `target_missing` \| `decrypt_failed` \| `key_unknown` | the phone will never admit it |
| `expired` | `pending` | — | the phone saw it past `expires_at_ms` |
| `completed` | `admitted` | — | the admission record reached `completed` |
| `failed` | `admitted` | `reason`: `target_missing` \| `not_authorized` \| `retry_exhausted` \| `run_failed` \| `expired` \| `cancelled` | the record reached `failed`, or `expired` / `cancelled` after admission |
| `unknown` | `admitted` | — | the record reached `unknown`; a terminal state, never rewritten to `failed` |

- First wins. Repeating the ack that produced the current state is `accepted: true,
  duplicate: true`. Any other ack on a non-`pending` task that the table does not allow is
  `accepted: false` with the unchanged `state`.
- A member the table does not list for that `state` is `400 invalid_request` for the whole call.
- The phone does **not** ack a task it could not admit for a transient reason (admission result
  `capacity` or `storage`, phone locked before first unlock): the lease expires and the task is
  redelivered.
- The cloud itself moves a `pending` task to `expired` at `expires_at_ms`, and an `admitted` task
  to `unknown` 21 days after admission if no terminal ack arrived. Terminal rows are kept 30 days
  for dedupe and status, then deleted. Sign-out (`DELETE` device) cancels only `pending` tasks.
- `linked` (handed to the outbox or the Bot) is never reported: accepted ≠ durable ≠ executed.

## 7. Phone admission mapping

For each pulled task the phone, in order: checks `expires_at_ms − now ≥ 1000` (else ack
`expired`; `now` is the pull response's `server_time_ms`, the phone's clock only if that member
is unusable), finds the private key for `key_id` (else `rejected` / `key_unknown`), opens `sealed`
with the §3 `aad` (else `rejected` / `decrypt_failed`; the same when the opened bytes are not
valid UTF-8 — an empty plaintext cannot reach this step, its 16-byte `ct` is an undecodable
element under §5), checks that the target exists (else
`rejected` / `target_missing`), then admits with

- `principal = "account:" + <signed-in user id>`, `source = {kind:"cloud-task", id: device_id}`,
  `sourceRequestId = task_id`, `target` from the task (`id` → `sessionId` / `botId`), `text` =
  the opened plaintext, `expiresAtMs = expires_at_ms`, a fresh `downstreamId`.

Admission results map to: `admitted` / `duplicate` → ack `admitted` with the record's
`admissionId`; `invalid` → `rejected` / `invalid`; `conflict` → `rejected` / `conflict`;
`capacity` / `storage` → no ack. The ack is sent only after the journal write returned.
Terminal acks are produced from the admission record's stage and are re-sent until accepted or
until the record is swept from the journal (after that the §6 21-day rule applies); the
phone keeps the pairing `task_id ↔ admissionId` in the record itself (`sourceRequestId`).
The mapping is total: `completed` → `completed`; `unknown` → `unknown`; `expired` → `failed` /
`expired`; `cancelled` → `failed` / `cancelled`; `failed` → `failed` with the record's `reason`
when it is `target_missing`, `not_authorized` or `retry_exhausted`, and `run_failed` for any
other or absent reason. (A record that expired or was cancelled was already acked `admitted`.)

The phone pulls when it becomes active, after sign-in, after a push, and after an ack that
returned work. Android may also use a best-effort WorkManager poll while signed in and opted in,
including on devices without FCM. The feature is off until the user enables it (preference key
`phone-dsh.cloud-tasks.enabled.v1`, boolean, absent = off); while off the phone neither registers
nor pulls, and turning it off deletes the registration.

## 8. Push (APNs and FCM)

After a submit is stored, and when a lease expires with the task still `pending`, the cloud may
send one hint to the device's registered push address. At most one push per device per 30 s.
Delivery failure or missing provider credentials never change task state.

- iOS receives the existing background notification. `apns-push-type: background`,
  `apns-priority: 5`, `apns-topic` equals the registered topic, with payload
  `{"aps":{"content-available":1},"pdsh":{"v":1,"kind":"phone-tasks"}}`.
- Android receives an FCM data-only message with data exactly
  `{"pdsh_v":"1","pdsh_kind":"phone-tasks"}`, normal priority and a bounded lifetime.
  The callback queues native authenticated pulling through WorkManager. It does not declare a
  foreground service exemption or an engine lease. A foreground host can run after admission
  through the existing launch orchestrator. Both providers are best effort.
- Ignore messages with an unknown task-hint version or kind. A push never supplies task data,
  identity or execution authority; only the existing authenticated pull → admit → ack does.
- APNs `410` or `BadDeviceToken` and FCM `UNREGISTERED` clear only the address that failed.
  A registration rotated while a request was in flight must survive the old address failure.

The iOS callback may boot or resume through host §10.2 if its granted window clears the relevant
threshold. Short or expiry-only windows do native work; durable records wait for the next
eligible wake. Routes and ciphertext, ack, dedupe, queue limits and APNs payload stay compatible.

## 9. Limits

| Limit | Value |
|---|---|
| task text | 16384 UTF-8 bytes |
| task lifetime at submit | 60 s – 7 days |
| pending tasks per device | 256 |
| devices per account | 8 |
| pull `limit` / acks per call | 16 |
| lease | 5–900 s, default 300 |
| long poll | ≤ 60 s |
| push spacing per device | 30 s |
