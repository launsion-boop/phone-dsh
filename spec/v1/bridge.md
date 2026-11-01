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

Names match `^[a-z][a-z0-9]*(\.[a-z][a-z0-9_]*){1,3}$` and are at most 64 characters. Namespaces
belong to the host; a page MUST NOT invent one. An unknown method is `BRIDGE_METHOD_UNKNOWN`.
## 12. Status: existing behaviour versus this document
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

Conformance vectors: [golden/bridge](golden/bridge), checked by [tools/bridge_check.py](tools/bridge_check.py)
against [schema/bridge-message.schema.json](schema/bridge-message.schema.json).
