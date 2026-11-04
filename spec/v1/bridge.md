# bridge.md — page ↔ host asynchronous message bridge (phone-dsh-v1, bridge 1)

Status: normative for `bridge 1`. The **page** is the DSH Web page inside the app's WebView; the
**host** is the native shell (Swift baseline, Kotlin port). This document fixes the page↔host bridge:
one JSON object per call, `requestId`-correlated answers, typed errors, deadlines, and the mechanism
each platform uses. Provenance tags: **[existing]** implemented in the Swift baseline, with citation;
**[NEW]** required here but not implemented yet; **NOT_VERIFIED** unmeasured on a device.
## 1. Scope, and the difference from [channel.md](channel.md)
| | [channel.md](channel.md) | bridge.md (this file) |
| --- | --- | --- |
| Parties | worker ↔ host | page (main frame) ↔ host |
| Transport | one ordered binary WebSocket | script-message handler / JS interface |
| Unit | 16-byte header + binary or JSON body | one JSON object per message |
| Correlation | `seq` per connection and direction | `requestId` per request |
| Carries | VFS, exec, journal, API, LIFECYCLE, worker CONSOLE | page console, native actions that need a result |
| Ordering | total, per connection | per `requestId` only |
| Failure | ERROR frame, connection closes | error envelope for one `requestId`; bridge survives |

The bridge carries no VFS mutation, exec event, journal record or remote API frame; those are
WebSocket-only (`Sources/PhoneDSHEngine/WebEngineScripts.swift:4-7`). A bridge error never closes the
channel and a channel error never rejects a bridge request. Worker console lines travel in CONSOLE
(`0x60`, [channel.md](channel.md) §4.6); page console lines travel here as §11 `console.line`.
## 2. Envelope
Every message is a JSON object carrying `v: 1` and `kind`. Unknown members are refused
(`additionalProperties: false` in [schema/bridge-message.schema.json](schema/bridge-message.schema.json)).

| Member | request | oneway | response | error |
| --- | --- | --- | --- | --- |
| `v` | 1 | 1 | 1 | 1 |
| `kind` | `request` | `oneway` | `response` | `error` |
| `requestId` | required | — | required | required |
| `method` | required | required | required | required |
| `params` | object, optional | object, optional | — | — |
| `result` | — | — | required | — |
| `timeoutMs` | integer, optional | — | — | — |
| `error` | — | — | — | required |

- A `request` is page→host and gets exactly one terminal `response` **or** `error` with the same
  `requestId`. The terminal echoes `method`; a mismatch is `BRIDGE_BAD_MESSAGE` [NEW: the echo; the
  baseline reply carries the id and `ok`/`code`, never a method, `WebEngineNativePreview.swift:228-238`].
- A `oneway` is fire-and-forget in either direction and is never answered. It has no envelope
  `requestId`; when an event belongs to a request, the id travels in `params` (§11).
- `response` and `error` are host→page only. `result` and `error` are mutually exclusive
  [existing `ok`/`code` split: `WebEngineNativePreview.swift:193-215`].
- `params` is always an object so method schemas stay open; a scalar argument is wrapped.
## 3. requestId
The page generates it; the host and the worker never do.

- Generation: `crypto.randomUUID()` when available (`plugins/phone-native-preview/src/protocol.ts:162-169`,
  `plugins/phone-directory-import/src/client/index.ts:194`), otherwise
  `<stem>-<base36 time>-<base36 counter>` (`protocol.ts:167-168`) [existing].
- Shape: `^[A-Za-z0-9][A-Za-z0-9._:-]{7,199}$` — 8 to 200 characters, no control characters or
  whitespace. The 200-byte cap and the control-character refusal come from the baseline
  (`WebEngineNativePreview.swift:52`, `:793-800`) [existing]; the pattern itself is [NEW].
- Uniqueness domain: one page document (one `window`, one bridge install) for its whole lifetime.
  The id is never reused after a terminal, a page-side timeout or a cancel [NEW]. Across documents
  and reloads it may repeat; the host treats it as opaque, never as a durable key.
- The host echoes the id verbatim: never shortened, normalised or re-minted.
## 4. Return values, binary, and size caps
`result` is any JSON value (`object`, `array`, `string`, `number`, `boolean`, `null`). `NaN` and
`Infinity` are not JSON and MUST NOT be sent [NEW]. Nothing live crosses — no handle, function or
structured clone; the host serialises before answering.

Binary bytes MUST travel as base64 in this two-member envelope and nowhere else:
`{"encoding": "base64", "data": "<base64>"}`. `data` uses the standard alphabet with padding, no
whitespace, no `data:` prefix, and decodes to at most 512 KiB (699 052 characters). This is the only
lossless textual form both platforms share: WKWebView bridges JSON-serialisable values only, and the
Android interface can return a `String` only. [NEW; no baseline bridge message is binary]

| Cap | Limit | Basis |
| --- | --- | --- |
| `request` / `oneway`, serialised | 256 KiB | one UI-thread hop on Android [NEW] |
| `response` / `error`, serialised | 1 MiB | [NEW]; unrelated to the channel frame budget (§1 of channel.md) |
| binary `data`, decoded | 512 KiB | leaves room under the 1 MiB response cap [NEW] |

"Serialised" means compact UTF-8 JSON; member order is irrelevant. An oversize inbound message is
refused with `BRIDGE_MESSAGE_TOO_LARGE`; a result over the cap is replaced by `BRIDGE_RESULT_TOO_LARGE`
and is never sent truncated, because a truncated result is a wrong result.
## 5. Errors
`error` is `{code, message, retryable?}`. `message` is at most 512 characters and carries no stack
trace, credential or local absolute path; the baseline truncates resolver errors to 300 characters
(`WebEngineNativePreview.swift:369-372`) [existing pattern].

| Code | When | Retries | Existing analogue |
| --- | --- | --- | --- |
| `BRIDGE_BAD_MESSAGE` | not an object, unknown or missing member, bad `requestId`/`method`, `method` echo mismatch | no | `invalid-message` (`:154`); "message must be an object" (`WebEngineDirectoryImport.swift:909-912`) |
| `BRIDGE_UNSUPPORTED_VERSION` | `v != 1` | no | `unsupported-version` (`:155`); "v must be 1" (`WebEngineDirectoryImport.swift:913-916`) |
| `BRIDGE_METHOD_UNKNOWN` | `method` not in the host registry | no | "action must be pick or cancel" (`WebEngineDirectoryImport.swift:937-938`) |
| `BRIDGE_INVALID_PARAMS` | `params` fails the method schema | no | "pick requires sessionId and an absolute targetDirectory" (`:923-927`) |
| `BRIDGE_SCOPE_DENIED` | caller is not the main frame of the loopback origin (§9) | no | main-frame messages are dropped (`WebEngine.swift:604`) |
| `BRIDGE_MESSAGE_TOO_LARGE` | inbound request/oneway over the §4 cap | no | — [NEW] |
| `BRIDGE_RESULT_TOO_LARGE` | result over the §4 cap | no | — [NEW] |
| `BRIDGE_TIMEOUT` | a deadline in §6 expired | yes | `preview-timeout` (`:165`) |
| `BRIDGE_CANCELLED` | cancelled or superseded (§7) | no | `preview-cancelled` (`:164`) |
| `BRIDGE_BUSY` | a one-owner resource is already taken | yes | `preview-busy` (`:163`) |
| `BRIDGE_UNAVAILABLE` | capability missing on this host | yes | analogous only: `ProviderError.unavailable` / `isRetryable` (`Sources/PhoneDSHAgentCore/ProviderError.swift:18`, `:31-37`), not the same enum |
| `BRIDGE_FAILED` | any other feature failure | no | `presentation-failed` (`:162`) |

A refusal that cannot be correlated (no usable `requestId`) is dropped without inventing an id: a
synthesised terminal would settle a Promise the page never created.
## 6. Timeout
- **Who times.** The page owns the Promise deadline, the host owns its answer deadline. Both run
  independently and neither replaces the other.
- **Page deadline.** Default 20 000 ms, which is the native-preview value [existing:
  `plugins/phone-native-preview/src/protocol.ts:216-223`]; the directory-import handler has none [NEW].
  On expiry the page settles with `BRIDGE_TIMEOUT`, deletes the pending entry and retires the id; a
  later terminal for a retired id is discarded. Retirement, as opposed to deleting the map entry
  (`protocol.ts:209-214`), is [NEW].
- **`timeoutMs`.** The page may send its deadline in the request (1 to 600 000 ms) [NEW]. The host
  answers before it, defaulting to `timeoutMs - 5000` with a 1 000 ms floor. The baseline's fixed
  15 s host deadline against the page's 20 s (`WebEngineNativePreview.swift:563`) is that same 5 s
  margin: existing margin, [NEW] general rule.
- **No dangling Promise.** The host MUST NOT drop an accepted request silently: every accepted
  `requestId` gets exactly one terminal, or the page deadline ends the Promise. A second terminal is
  a protocol error and is discarded. This rule is what makes the Android thread hop safe [NEW].
- **Order.** The page deadline is authoritative; an answer arriving after it is lost, so the host
  SHOULD keep its deadline shorter than `timeoutMs`. Page or renderer death produces no terminal at
  all: only the page deadline ends that Promise (renderer loss is NOT_VERIFIED on device, [NEW]).
## 7. Cancellation
- Cancel is the oneway `bridge.cancel` with `params: {requestId}` [NEW name; behaviour exists:
  `action: "cancel"` (`WebEngineDirectoryImport.swift:933-936`,
  `plugins/phone-directory-import/src/client/index.ts:219-231`), and host-side supersede
  (`WebEngineNativePreview.swift:656-667`)].
- The host stops what it can stop and answers the cancelled request with `BRIDGE_CANCELLED` when
  that request has no terminal yet. If it has one, the host sends nothing: a second terminal is a
  protocol error.
- A cancel for an unknown or retired id is dropped. The id is dead, and a new error would need an id
  the page no longer tracks.
- Cancel is never a `request`: it must not create a pending entry that the page then has to time out.
## 8. Ordering and delivery
- **Per `requestId`:** the request precedes its terminal, and there is one terminal only.
- **Across `requestId`s:** unordered. The host may answer out of order and the page MUST NOT infer
  causality from arrival order.
- **Per direction, `oneway`:** delivered in post order. On iOS `postMessage` enters the host queue
  synchronously (`WebEngineScripts.swift:36-38`); on Android the interface method runs on a WebView
  binder thread, so the host MUST move messages onto one FIFO dispatcher before touching state, or
  the order is lost [NEW, NOT_VERIFIED on device].
- **No retransmission, no replay.** A reload destroys the page's pending map, so a page MUST fail its
  own pending Promises on `pagehide`/navigation instead of waiting for the deadline.
## 9. Scope: same-origin main frame only
The bridge is reachable from the main frame of the loopback origin and from nothing else. A subframe
of any origin MUST NOT be able to send a request, and MUST never receive a capability.

- **iOS.** One `WKUserContentController` per WebView, one handler registration, and the user script
  injected with `forMainFrameOnly: true` (`WebEngine.swift:209-214`); every handler re-checks
  `message.frameInfo.isMainFrame` (`WebEngine.swift:604`, `WebEngineNativePreview.swift:622-625`). A
  cross-origin subframe therefore has neither handler nor shim [existing].
- **Android.** `addJavascriptInterface` exposes the object to **every** frame, so it is not
  sufficient alone. Either use `WebViewCompat.addWebMessageListener` with `allowedOriginRules` plus
  the delivered message's `isMainFrame`, or keep `addJavascriptInterface` and gate every call on a
  per-document nonce injected only into the main frame by `evaluateJavascript` (main-frame only)
  [NEW; `addWebMessageListener` availability on an M99-class WebView is NOT_VERIFIED].
- A call that reaches the host without that proof is answered `BRIDGE_SCOPE_DENIED` when the host can
  answer at all, and dropped otherwise. It never reaches method dispatch, so it cannot probe which
  methods exist.
- One WebView per app process [DECISION: a second WebView would need its own handler name and would
  double the single-renderer exposure].
## 10. iOS ↔ Android mapping of the same semantics
| Semantics | iOS (WKWebView) | Android (WebView) |
| --- | --- | --- |
| page sends | `window.webkit.messageHandlers.pdshBridge.postMessage(obj)` | `window.__PDSH_BRIDGE__.post(json)` |
| host receives | `WKScriptMessageHandlerWithReply` `userContentController(_:didReceive:replyHandler:)` (`WebEngineDirectoryImport.swift:906-908`), or `WKScriptMessageHandler` + `evaluateJavaScript` (`WebEngineNativePreview.swift:620-631`) | `@JavascriptInterface fun post(token: String, json: String): String`, invoked on a WebView binder thread |
| synchronous return | none: `postMessage` returns `undefined`; WithReply returns a Promise | MUST return a JSON string synchronously — `{"accepted":true}`, or a `kind:"error"` envelope for an immediate refusal (`BRIDGE_SCOPE_DENIED`, `BRIDGE_BAD_MESSAGE`, …). Only `String` and primitives cross; the method MUST NOT throw and MUST NOT block |
| host answers | `replyHandler(envelope, nil)`, or `evaluateJavaScript("window.__PDSH_BRIDGE__.settle(<json>)")` (`WebEngineNativePreview.swift:783-791`) | `evaluateJavascript("window.__PDSH_BRIDGE__.settle(<json>)", null)`, on the UI thread only |
| transport failure | handler throws → `postMessage` throws; WithReply rejects with a `String` | interface throws → JS exception; the page maps both to `BRIDGE_FAILED` |
| cancel / events | oneway `bridge.cancel`; events are oneway, today `new CustomEvent(...)` (`WebEngineDirectoryImport.swift:825`) | oneway `bridge.cancel`; events use the same `settle`/`emit` shim |

Two rules keep this honest: (1) the synchronous Android return is an **ack**, not a bridge message,
unless it is a `kind:"error"` envelope — the `window.__PDSH_BRIDGE__` shim normalises both platforms
into one Promise API, so page code never branches on the platform; (2) WithReply can carry a result
directly, but the baseline uses it as an ack and streams the outcome as a `CustomEvent`
(`WebEngineDirectoryImport.swift:929-936`, `:825`) [legacy] — moving it onto this envelope is [NEW]
and is what makes both platforms look identical to the page.
## 11. Method registry
| Method | Direction | Kind | Status |
| --- | --- | --- | --- |
| `preview.open` | page→host | request | capability implemented (native preview, `WebEngineNativePreview.swift:560`); name [NEW] |
| `directory.pick` | page→host | request | capability implemented (directory import, `WebEngineDirectoryImport.swift:509`, `:921-932`); name [NEW] |
| `bridge.cancel` | page→host | oneway | behaviour implemented (`:933-936`); the name is [NEW] |
| `console.line` | page→host | oneway | implemented as `{kind:"console",level,text}` (`WebEngineScripts.swift:36-48`); envelope [NEW] |
| `directory.progress` | host→page | oneway | implemented as `CustomEvent` (`WebEngineDirectoryImport.swift:825`); envelope [NEW] |
| `file.read` | page→host | request | reserved, no implementation — it exists only to fix the binary vector |
| `ubuntu.exec` | page→host | request | **not implemented**: no host method, no adapter, no job record. Name [NEW] and capability [NEW] (§12) |
| `ubuntu.status` | page→host | request | **not implemented**; name [NEW] and capability [NEW] (§12) |
| `ubuntu.fetch` | page→host | request | **not implemented**; name [NEW] and capability [NEW] (§12) |

Names match `^[a-z][a-z0-9]*(\.[a-z][a-z0-9_]*){1,3}$` and are at most 64 characters. Namespaces
belong to the host; a page MUST NOT invent one. An unknown method is `BRIDGE_METHOD_UNKNOWN`.

Two readings of `[NEW]` are in this table and must not be confused. On the rows before the `ubuntu.*`
group it means the *name only* is new: the capability exists in the baseline and the row cites it. On
the three `ubuntu.*` rows nothing exists — the method, the adapter that would run a command and the
audit record are all absent — so `[NEW]` means "required here, not implemented yet". A row marked
**not implemented** has no implementation to cite and MUST NOT be read as shipped.

## 12. `ubuntu.exec` — one external-environment job, asynchronously

**Status of this section: `[NEW]`: required here and not implemented.** No host registers these
methods, no adapter exists and no job record is written on either platform; §11 marks the three rows
`not implemented` for exactly that reason, and §13 repeats it. The text is normative all the same: it
is what an implementation must do, and it fixes the vocabulary so the two ports cannot answer these
questions differently. It adds no frame, no capability string, no ERROR code and no VFS surface.

### 12.1 One capability face, N environments

`ubuntu.exec` runs **one command in a named external environment** and returns a job, not a result:
"hand this command to that place and give me a handle" (`exec.md` §3's executor inversion is
unchanged; this is a host tool, not an accelerator and not a second execution domain). The
environment is a **parameter**, never a method name:

```
ubuntu.exec --env ubuntu-24.04            -- <command…>
ubuntu.exec --env gh-actions:ubuntu-latest -- <command…>
```

Lint, test, codegen and build are one capability. A separate `build.run`, `lint.run`, `test.run` would
be one grant split into four names, and the consent surface a user approves would stop describing what
the grant actually allows: *run any script in an external environment*. `env` is opaque to the page,
matches `^[a-z0-9][a-z0-9.:-]{0,63}$`, and is resolved by the host's adapter registry. There is no
shell: `argv` is an array of strings, exactly like `EXEC_REQ` (`channel.md` §4.2).

### 12.2 The call admits a job; `ubuntu.status` reads it

Three existing bounds make a blocking call impossible: the shell's 120 s wall clock, a suspended
WebView inside a backgrounded app (a blocked call pins the session), and the 20 s `Draining` deadline
(`budgets.md` §1). So `ubuntu.exec` **admits** a job and answers a `JobRef`; the host drives the job
from its own loop and §12.8's status reads a durable record without waiting for the adapter. The
page's `requestId`, `timeoutMs` and deadline bound the *call*; `jobTimeoutMs` bounds the *job*, and a
page timeout neither shortens nor cancels one. §6's "no dangling Promise" is satisfied because the
call has returned before the command starts.

| Method | `params` | `result` |
| --- | --- | --- |
| `ubuntu.exec` | `{env, argv, workspace?, cwd?, label?, jobTimeoutMs?, session?}` | `{job}` — the §12.2 `JobRef` |
| `ubuntu.status` | `{jobId}` | §12.8 |
| `ubuntu.fetch` | `{jobId, name, offset?, path?}` | `{jobId, name, offset, bytes, eof, limits, chunk?, refusal?}` |

- `env` is required (§12.1's pattern); `argv` is required, 1–256 strings of 1–8192 bytes with no NUL, and the whole
  `params` must fit §4's 256 KiB request cap (an `argv` above 64 KiB in total is
  `BRIDGE_INVALID_PARAMS`, so the cap is reached before the envelope's).
- `workspace` (default `/dsh/workspace`) names the one workspace subtree the job may read; the
  outbound snapshot is staged under `tmp`, so it is bounded by that bucket (50 MB at the 8 GiB row,
  `budgets.md` §4) and a larger input is `failed`/`snapshot_too_large`, never a silent truncation.
  `cwd` (default `/dsh/workspace`) is the guest working directory and must be inside `workspace`.
- `label` is 0–120 characters for the audit line, never a credential. `jobTimeoutMs` is 1 000 to
  3 600 000, default 600 000.
- `session` is the DSH session the **approval gate** binds to (design §3 layer 1: one approval covers every later job in that session); the Worker supplies it from its trusted tool-call context, never a caller flag — a command must not choose which session's approval it spends — and an absent `session` binds nothing (the gate then asks on every job); it follows `channel.md` §6.
- The `JobRef` is `{jobId, env, state, seq, createdAtMs, updatedAtMs, egress, authorityExited, argvDigest, exec, limits, approval}`: `jobId` matches `channel.md` §6's identifier rule and is unique for the workspace's lifetime, `argvDigest` is the lowercase sha256 of the canonical JSON `argv` (`channel.md` §5) so the audit can name the command without storing it, `exec` is `{argvLength, cwd, workspace}`, `limits` is `{fileLimitBytes, workspaceLimitBytes, rssLimitBytes?}`, and `approval` is `{state, sessionId?, atMs} | null`: `state` is `granted`/`denied`/`unavailable`, `sessionId` is the bound session (or `null` when the caller had none), `atMs` is when the decision was taken, an approval refusal still writes a record (§12.3) so `status` answers for an attempt that never ran, and `null` means "this record cannot say", never "the user approved".

### 12.3 Job states, every transition, and the boot mapping

Nine states, four of them terminal, and no other state exists. `job.state` is one of these literals.

| State | Terminal | Meaning |
| --- | --- | --- |
| `admitted` | no | The record and its audit line are durable; nothing has left the host. |
| `sealing` | no | The three internal roots are being sealed; a job may not reach an adapter before the seal holds. |
| `handingOff` | no | The input snapshot and the command are crossing to the environment; authority is leaving `worker-vfs`. |
| `remote` | no | The environment owns the execution; DSH polls and holds no execution authority over it. |
| `reclaiming` | no | The command is over (or was stopped); exit, log tail and the artifact manifest are coming back, the seal is restored. |
| `succeeded` | yes | An exit code was recorded, the manifest is known, the seal is restored. |
| `failed` | yes | No exit code will ever be recorded; `failure` is present. |
| `cancelled` | yes | A page cancel or a host drain stopped the job; `failure` is present. |
| `ingestRefused` | yes | The command ran and its exit code is recorded, and at least one artifact cannot be ingested. |

| # | From | To | Trigger (who) | Guard, and what is written |
| --- | --- | --- | --- | --- |
| 1 | — | `admitted` | host, in the `ubuntu.exec` handler | The request passed the §4 caps. Record `env`, `argvDigest`, `limits`, `egress = false`, `authorityExited = null` (nothing has moved yet); `seq = 1`. |
| 2 | `admitted` | `sealing` | host lane | `env` resolves to an adapter, admission is open, the §12.9 prechecks pass. |
| 3 | `admitted` | `failed` | host lane | Any guard of #2 fails: `cause` is `env_unavailable`, `admission_closed`, `memory_insufficient` or `snapshot_too_large`; `outcome = "not_started"`. |
| 4 | `sealing` | `handingOff` | host lane | All three roots read back sealed and the restore preflight succeeds. |
| 5 | `sealing` | `failed` | host lane | The seal or its preflight failed: `cause = "seal_failed"`, `outcome = "not_started"`, and **no adapter is contacted** (fail-closed). |
| 6 | `handingOff` | `remote` | adapter acknowledgement | The adapter accepted the snapshot and started `argv`. `authorityExited` takes effect here; a boot after this point may never report it as `null`. |
| 7 | `handingOff` | `failed` | host lane, adapter, or boot | The adapter refused or died. `outcome` is `not_started` only if the adapter proves no `argv` ran, else `"unknown"`. |
| 8 | `handingOff` | `cancelled` | page `bridge.cancel`, host drain | The adapter acknowledges the stop. Without an acknowledgement inside the drain deadline it is #7 with `cause = "drain_deadline"`. A host MAY take the longer `remote` → `reclaiming` → #13 path when it wants the observed exit code on the record; then this row is not taken. |
| 9 | `remote` | `reclaiming` | host poller: adapter exit observed; or host cancel, drain or `jobTimeoutMs` | The only exit from `remote`. A cancel and a timeout both ask the adapter to stop first; the job waits for the exit, bounded by the drain deadline. |
| 10 | `remote` | `failed` | host poller, or boot | The adapter is gone or unanswered past its deadline, or the host found memory-pressure evidence (§12.9): `outcome = "unknown"`. |
| 11 | `reclaiming` | `succeeded` | host lane | Exit recorded; every manifest entry prechecked and fetchable (or the manifest is empty); seal restored; `internalAccessObserved` written. |
| 12 | `reclaiming` | `ingestRefused` | host lane | As #11, except the manifest precheck refused at least one entry (§12.7). The exit code is still recorded. |
| 13 | `reclaiming` | `cancelled` | page `bridge.cancel`, host drain | The ingest stops between two mutations; entries already written stay written and their state says so. |
| 14 | `reclaiming` | `failed` | host lane, or boot | The exit could not be obtained inside the drain deadline (`provider_timeout`), or the record cannot be written; `outcome = "unknown"`. |
| 15 | `succeeded` | `ingestRefused` | host, on a later fetch | A fetch of an approved artifact was refused for a resource reason. This is the **only** legal edge out of a terminal state, it happens once, and it exists so the record can stop being wrong. |

No other edge exists, and every non-terminal state above has at least one way out, so a job cannot be
left in flight by the absence of a row.

**Which refusals create a record.** An accepted `ubuntu.exec` always writes one, and everything after
admission is a state. A request that never became a job writes nothing and is answered with the §5
envelope: `BRIDGE_BAD_MESSAGE`, `BRIDGE_INVALID_PARAMS`, `BRIDGE_MESSAGE_TOO_LARGE`,
`BRIDGE_SCOPE_DENIED`, `BRIDGE_METHOD_UNKNOWN`, and `BRIDGE_BUSY` — one non-terminal job per
workspace, because two guests do not fit the app-process row. Everything from `env` resolution
onwards is a terminal state instead, because a user must be able to see in the audit what was
attempted even when nothing ran.

**The approval gate is the one refusal before `admitted` that writes a record**: it runs before row 1 and admits nothing when it says no, so it is not a transition — the host writes one record already `failed`, with `outcome = "not_started"`, `cause = "approval_denied"` (a denial) or `"approval_unavailable"` (no surface, or no answer in time), plus the §12.2 `approval` member. The user's decision is testimony the audit must keep (a log line would not survive a restart, and `ubuntu.status` answers "what did I refuse, and when"), and nothing reached an adapter, so `not_started` is a fact. The concurrency bound is **not** the approval granularity: one approval covers a session's jobs, while one non-terminal job at a time is a *resource* bound (two guests do not fit the app-process row), and the two never widen each other.

Boot mapping, which is `budgets.md` §3's pinned rows applied to a job. A boot repairs a seal left
behind by #4 before it does anything else (a `chmod` restore is idempotent, and a process killed
inside `sealing` or `handingOff` must not leave the internal roots sealed), and a job it resumes
re-seals before it resumes: the window follows the job, not the process. A seal that will not
re-form fails the resumed job with `outcome: "unknown"` — the command may already have run, so
`not_started` would be a claim the host cannot support.

| Persisted state | Boot result |
| --- | --- |
| `admitted`, `sealing` | `failed`, `outcome = "not_started"`, `cause = "host_lost"`; no adapter was contacted, so this is not a guess. |
| `handingOff` | `failed`, `outcome = "unknown"`, `cause = "handoff_lost"`; a half-finished handoff cannot be replayed. |
| `remote` | **stays `remote`** and polling resumes; the adapter is the authority and answers per `jobId`. |
| `reclaiming` | resumes `reclaiming`; the terminal pull is idempotent and every precheck re-runs. |
| a terminal state | unchanged. |

### 12.4 How this aligns with `budgets.md` §1 and `handoff.md`, without a second authority machine

`handingOff`, `remote` and `reclaiming` are the same three legs as the host's `HandingOff`, `Remote`
and `Reclaiming`, with the same guards and the same failure rules, applied to **one job** instead of to
the session's fence:

- the host's legs transfer the *session's* execution authority and advance `fence.generation`
  (`handoff.md` §1, §2); a job's legs transfer *one command* to an environment and never touch the
  fence, a `wal_seq`, or admission;
- admission stays closed to the affected work in both: a job's artifacts may not be ingested before
  it is terminal, and the host starts no new job while one is non-terminal;
- `remote` survives a process death and resumes by re-reading the authority, in both (`handoff.md` §5
  cold recovery; `Remote → Reclaiming` at boot in `budgets.md` §3);
- a lost `handingOff` is unrecoverable in both (`budgets.md` §3: persisted `HandingOff` → `Failed`);
- a lost `remote` produces `outcome: "unknown"` and is never retried automatically, in both
  (`exec.md` §2.2).

What is **not** shared is the record: the host state (§1 of `budgets.md`) stays the only authority
state and `HostState` is not a bridge concept. `ubuntu.status` never reports a host state, and a job
state never opens admission, so the two machines cannot contradict each other: one is the session's
authority, the other is one command's location.

### 12.5 `egress` and `authorityExited` are two fields and are never merged

Both are written **at the moment the fact becomes true** and are never rewritten afterwards, not even
by a boot: `egress` starts `false` and may only move to `true` at #6, `authorityExited` starts `null`
and takes the adapter's declared value at #6.

| Member | Type | Meaning |
| --- | --- | --- |
| `egress` | boolean | `true` if and only if a byte of this job left **this device**: `argv`, the input snapshot, stdout or an artifact. |
| `authorityExited` | string or `null` | Which authority the job's execution left: `"worker-vfs"` (it left the Worker's VFS enforcement point, `channel.md` §6, and stayed on the device), `"device"` (it also left the device), or `null` (no byte and no execution left any authority: the adapter was never contacted). |

A local same-UID guest has **not** left the device, but it has left the Worker's authority, so
`{"egress": false, "authorityExited": "worker-vfs"}` is the true pair and a cloud adapter is
`{"egress": true, "authorityExited": "device"}`. Writing `egress: true` for a local job would be
false; writing only `egress: false` would hide that the bytes are outside the enforcement point that
`channel.md` §6 names. The audit is append-only testimony under a governance in which the spec is the
only judge, so neither field may stand in for the other and a later status may not rewrite either.

Invariants: `authorityExited == "worker-vfs"` implies `egress == false`; `"device"` implies
`egress == true`; `null` implies the job never reached #6, so it is the value of every
`not_started` job and of every cancel that happened before the adapter was contacted.

### 12.6 Failures reuse the existing vocabulary; nothing new is coined

`failure` is `{code, message, outcome, retryable, foreground_required?, cause?}`, the shape
`plugins/shell-ext/src/phone-errors.ts` already returns to the worker, with `code` from the same set.
`outcome` is one of the existing `not_started`, `cancelled`, `unknown`; `cause` is the existing
sub-reason member, not a new code. `retryable` is `false` whenever `outcome != "not_started"`, because
the command may have run (the rule `exec.md` §2.2 states for artifact-producing writes); for a job
that did not start it is the cause's judgement — `true` for `admission_closed` and
`memory_insufficient`, `false` for `env_unavailable`, `seal_failed` and `snapshot_too_large`, none of
which a retry of the same command can fix. `approval_denied` is `false` too: the denial is bound to the session, so the same run would be refused again until the session ends or the user revokes (design §3 layer 1).

| Condition | `state` | `failure.code` | `outcome` | `cause` |
| --- | --- | --- | --- | --- |
| No adapter for `env` | `failed` | `provider_unavailable` | `not_started` | `env_unavailable` |
| Pre-start budget precheck fails (memory, snapshot staging) | `failed` | `provider_unavailable` | `not_started` | `memory_insufficient`, `snapshot_too_large` |
| The seal or its preflight fails (fail-closed, job must not start) | `failed` | `provider_unavailable` | `not_started` | `seal_failed` |
| Admission is closed when the lane starts | `failed` | `admission_closed` | `not_started` | — |
| The host drains while the job is in flight and the adapter acknowledges the stop | `cancelled` | `cancelled` | `cancelled` | `host_draining` |
| The same, and the adapter does not acknowledge inside the drain deadline | `failed` | `provider_timeout` | `unknown` | `drain_deadline` |
| The command outlived `jobTimeoutMs` and cannot be observed | `failed` | `provider_timeout` | `unknown` | `job_timeout` |
| The system reclaimed the process under memory pressure (§12.9 evidence) | `failed` | `provider_unavailable` | `unknown` | `memory_reclaimed` |
| The process died with the job in `handingOff`/`remote`/`reclaiming` | `failed` | `provider_unavailable` | `unknown` | `handoff_lost`, `host_lost`, `ingest_lost` |
| The process died before any adapter was contacted | `failed` | `provider_unavailable` | `not_started` | `host_lost` |
| A cancel or a drain arrived before any adapter was contacted | `failed` | `cancelled` | `not_started` | `page_cancel`, `host_draining` |
| The user declined the local environment for this session (§3 layer 1) | `failed` | `cancelled` | `not_started` | `approval_denied` |
| No confirmation could be shown, or none was answered in time | `failed` | `provider_unavailable` | `not_started` | `approval_unavailable` |
| The adapter refused to start the command | `failed` | `provider_unavailable` | `not_started` | `adapter_refused` |
| The adapter no longer knows the job, or failed in flight | `failed` | `provider_unavailable` | `unknown` | `adapter_gone`, `adapter_failed` |
| A resumed job cannot re-establish its seal | `failed` | `provider_unavailable` | `unknown` | `seal_failed` |
| An artifact exceeds an ingest limit | `ingestRefused` | — (per artifact, §12.7) | — | — |

`foreground_required` is `true` only for `admission_closed`, where the recovery is literally "come
back to the foreground". A seal failure is **not** `admission_closed`: the host is admitting work and
refusing this job, which the audit must be able to tell apart.

### 12.7 Artifacts: a manifest first, bytes on demand, and never an automatic materialization

The workspace bucket is 288 MB and a single mutation carries at most 15 MiB (`budgets.md` §4,
`channel.md` §6), while a real artifact is tens to hundreds of MiB. "The protocol accepts the write"
therefore never meant "the write fits", and a job that poured its artifacts into `/dsh/workspace`
would fill the one bucket the user's work lives in. So:

- `reclaiming` carries a **manifest** and no bytes: at most 32 entries of
  `{name, bytes, sha256?}`, `name` matching `^[A-Za-z0-9._-]{1,64}$` and not `.` or `..`. The manifest
  is persisted with the job and survives a restart; an adapter that reports more is `failed` with
  `cause = "adapter_failed"`, not truncated, because a silently shortened manifest is a wrong one.
- The ingest precheck runs once, at `reclaiming`, **in ascending `name` order**, against
  `limits.fileLimitBytes` and the workspace bucket, adding each accepted `bytes` to the running total.
  The verdict decides `succeeded` versus `ingestRefused`, so "the job succeeded but the ingest failed"
  is known before a byte moves and cannot be discovered halfway.
- A refused entry is `VFS_REFUSED` with the existing `reason`, `channel.md` §4.8's own refusal for a
  resource limit: `file-too-large` with `limit = limits.fileLimitBytes`, or `quota-exceeded` with
  `limit` = the workspace bucket. It is not a job failure and not a new code.
- `ubuntu.fetch` pulls one artifact on request, at most 524 288 decoded bytes per call (§4's binary
  cap), each chunk idempotent per `offset`, and **the host stages nothing**: bytes come from the
  adapter at fetch time, so a manifest costs no workspace bytes and an expired adapter retention
  makes an entry `missing` instead of silently serving a stale copy. Its result carries `limits` (the JobRef's `{fileLimitBytes, workspaceLimitBytes, rssLimitBytes?}`) so the page can refuse an impossible write **before** it moves a byte.
- The page (the Worker) writes the bytes with the mutations `channel.md` §6 already fixes: one complete `op = 1` write of at most 15 MiB, then appended suffixes whose `append_from` is the accepted logical length. The append chain is how a raised limit is honoured; the 15 MiB boundary is
  the mutation's, never the file's. `--offset` resumes at an accepted prefix: the target must exist with exactly that many bytes, and the next mutation is an append from it.
- A refusal happens **before the first write**: the host's `fileLimitBytes` precheck at `offset = 0` and the page's own `single_file_limit` are both applied to the artifact's whole size first, so `VFS_REFUSED` / `file-too-large` (or `quota-exceeded`) leaves no file behind; a genuine mid-chain failure (the device fills up) is reported as the prefix it left, with its byte count and a resume offset, never as a silent success.
- `limits.fileLimitBytes` defaults to 15 MiB (15 728 640) so that the default ingest is one atomic
  mutation that cannot leave a half-written file, and an environment may raise it up to the tier's
  `single_file_limit` (16 MiB … 256 MiB, clamped as `budgets.md` §4 clamps that value). The raise is
  **declared in the JobRef**, so the limit is a published number and never a surprise.

### 12.8 What `ubuntu.status` answers

`{job, exitCode, logTail, artifacts[], failure, internalAccessObserved, seal}`, all bounded and
read-only (and `approval` is inside `job`):

- `job` is the current `JobRef` (§12.2), including `state`, `seq`, `egress`, `authorityExited` and
  `limits`. `seq` increases by one per state change and per artifact-state change, so two polls tell a
  reader whether anything happened without re-reading the world.
- `logTail` is the tail, at most 262 144 UTF-8 bytes, cut on a code-point boundary and prefixed with
  one `[truncated <bytes>]` line when it is a tail of something larger. A tail is never a head: a
  command's last lines are what a failure needs.
- `internalAccessObserved` is `true` at job end if the seal was breached and the tripwire saw it,
  `false` if the seal held through the window, `null` while the window is still open. It is per job,
  and it is the field that keeps "not off the device" from being read as "not looked at".
- `artifacts` has one entry per manifest line: `{name, bytes, sha256?, state, path?, refusal?}`, with
  `state` from `available` (prechecked, fetchable), `ingested` (written to `path`), `refused`
  (precheck said no, and `refusal` says why), `partial` (a mutation chain stopped halfway) or
  `missing` (the adapter no longer has the bytes). `refusal` is `{code: "VFS_REFUSED", reason,
  limit, bytes}` — the sink's own refusal, not a new vocabulary.
- A refused `ubuntu.fetch` answers `{fetched: false, refusal}` in `result`, not in the error envelope:
  §5's code set is closed and `VFS_REFUSED` is not in it, while a prose `BRIDGE_FAILED` would force
  the page to parse a message for a number it needs. `result.refusal` is the same structure as
  `artifacts[].refusal`, so one reader handles both. The target `path` defaults to
  `/dsh/workspace/.ubuntu/<jobId>/<name>` (a `channel.md` §6 mutation path) and may be given
  explicitly; a `path` that exists and is not this job's artifact for this `name` is
  `BRIDGE_INVALID_PARAMS`, because the method never overwrites a file it does not own — while a
  re-fetch after an interrupted chain converges on the job's own path. A fetch of a job that is not
  terminal is `BRIDGE_BUSY`: there is no manifest to fetch from yet.
- `seal` is `{state, reason}` with `state` one of `pending`, `sealed`, `restored`, `failed`, and
  `reason` a short token (`chmod_failed`, `verify_failed`, `restore_failed`, `marker_unreadable`)
  copied from the seal's stable code. It answers "was the workspace protected, and is it protected
  now", which is a different question from the job's outcome: a successful job with a failed restore
  keeps `state: succeeded` — the exit code is a fact — while `seal.state` says `failed`.

### 12.9 Draining, deadlines and memory

- On `Running → Draining` (`budgets.md` §2) the host persists the job's move to `reclaiming` **before
  the drain completes**, then asks the adapter to stop and waits inside the 20 s deadline. After that
  write, no `ubuntu.status` may answer `remote` for that job: the record is the answer, and a poll that
  reports `remote` for a job the host has abandoned would be the audit lying about where the work is.
- The job deadline (`jobTimeoutMs`, default 600 000, at most 3 600 000) is enforced by the host, not
  by the adapter's goodwill. The host asks the adapter to stop and waits; an exit it then observes is
  an **exit code** (124 is the deadline value `exec.md` already uses), so the job is `succeeded` with
  that code. A job whose exit cannot be observed past its deadline is `failed` with
  `provider_timeout` and `outcome: "unknown"`, never `succeeded` with a guessed exit.
- Before #2 the lane prechecks available memory against the environment's declared `rssLimitBytes`
  (absent means the `budgets.md` §4 app-process row) and refuses to start rather than be killed
  halfway. A job found non-terminal at boot is `failed` with `cause = "host_lost"` unless the host
  recorded memory-pressure evidence after the job's last transition, in which case the cause may
  name `memory_reclaimed` — a cause is named only from evidence, because the audit is testimony.

## 13. Status: existing behaviour versus this document
| Rule | Status |
| --- | --- |
| request/response correlation by id, one reply | [existing] `WebEngineNativePreview.swift:629-667`, `protocol.ts:206-231` |
| feature error codes on the reply | [existing] `WebEngineNativePreview.swift:151-166`; the unified table is [NEW] |
| main-frame-only delivery | [existing] on iOS (`WebEngine.swift:604`); the Android gate is [NEW] |
| a timeout with a page-side deadline | [existing] per feature (`protocol.ts:216-223`); `timeoutMs` and the general rule are [NEW] |
| no `requestId` reuse after a terminal; `method` echo on terminals | [NEW] |
| 256 KiB / 1 MiB / 512 KiB caps and base64 | [NEW] |
| cancel as a oneway | [NEW] name, [existing] behaviour |
| same-origin scope on Android | [NEW], NOT_VERIFIED |
| `ubuntu.exec` / `ubuntu.status` / `ubuntu.fetch` and the §12 job machine | [NEW], **not implemented** on either platform: §12 is a specification, not a report of behaviour |

Conformance vectors: [golden/bridge](golden/bridge), checked by [tools/bridge_check.py](tools/bridge_check.py)
against [schema/bridge-message.schema.json](schema/bridge-message.schema.json).
