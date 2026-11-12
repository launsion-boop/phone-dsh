<!-- SPDX-License-Identifier: MIT -->

# Bot MCP endpoint, identity and restart contract (Bot v1)

Status: normative for the App/Worker `phone` MCP endpoint introduced by the Bot
runtime. Contracts: P05 (HTTP/MCP gateway), P16 (Worker environment), P25
(BotEventLog), P26 (BotToolSurface). Contract revision:
`bot-identity-reclaim-v1` (PC-20261111-bot-identity-reclaim); the D13 JSON-RPC,
identity/approval, credential, listener and HTTP-body clauses (§7–§11) are
revision `bot-mcp-d13-v1` (PC-20261113-bot-mcp-d13).

This document is the owning contract for the single `phone` MCP endpoint the
Worker sees. It does not define a new transport: it reuses MCP Streamable HTTP,
the existing Bot JSON-RPC messages and the existing BotEvent log.

## 1. One owner for the Worker environment and the MCP egress capability

- When the App runs the Bot runtime, `PDSH_PHONE_MCP_URL` and
  `PDSH_PHONE_MCP_TOKEN` point at the Bot MCP listener and that listener is the
  Worker's only `phone` server. `PhoneDSHHost` must not replace the URL with
  `/mcp/native` merely because `PhoneDSHConfiguration.nativeMCP` is set.
- A native-only configuration (no App-supplied `PDSH_PHONE_MCP_URL`) keeps the
  legacy `/mcp/native` endpoint and loopback token. The authenticated
  `/mcp/native` HTTP route remains available for other callers in both cases.
- The Worker value is never the real Bot bearer. The App injects the bearer at
  its `/v1/http` egress for exactly `/mcp`, `/identity/register`,
  `/identity/cancel` and `/approval`; the page URL (`?env=`) and the Worker
  process only ever see the documented non-secret placeholder.

### 1.1 MCP egress credential

- **Value and delivery.** The App generates one random
  `PDSH_MCP_EGRESS_TOKEN` per host start (at least 128 bits from the system
  CSPRNG, encoded as lowercase hex; it is never the loopback/channel token, the
  Bot bearer or a placeholder) and delivers it through the same `?env=` Worker
  boot map as `PDSH_CHANNEL_TOKEN`
  (`PhoneDSHWorkerEnvironment.mcpEgressToken`, `PhoneDSHHost.workerEnvironment`).
  The App keeps the value in host memory only.
- **Trusted clients.** Every trusted Worker MCP client adds
  `X-PDSH-MCP-Egress: <value>` to each request whose target is an exact MCP
  route: the profile `mcp-phone` mount (both Worker profiles), the mounts created
  by `plugins/phone-mcp` from `/dsh/home/mcp.json`, `identity-bridge`
  (`/identity/register` and `/identity/cancel`), the shared `postApproval` in
  `approval-gate` (also used by `sandbox-approval`), and `caller-catalog`
  (`tools/list`). `volatile-mcp` has no direct fetch: its
  `mcp__phone__BotVolatileContext` call is carried by the `mcp-phone` mount. A
  client whose environment value is absent or empty omits the header and the
  request fails closed.
- **No generic injection.** The generic Worker `/v1/http` transport, the
  `curl` shim, the `git` smart-HTTP transport, the WASI Python XHR bridge and
  the PTC guest never add this header. They have no API that reads the token on
  behalf of model-written code.
- **Host gate.** Before resolving a credential or constructing an upstream
  request, the host tests the target against the same exact
  scheme/host/effective-port/normalized-path predicate that decides MCP
  credential injection (`MCPEgressPolicy.allowsEgressHost`). For every match
  (the four Bot routes and every user-configured connector route), it requires a
  header whose value equals the current `PDSH_MCP_EGRESS_TOKEN`, compared in
  length-independent constant time. Missing, empty or different (including
  either `PDSH_PHONE_MCP_TOKEN` placeholder and any case-shifted value) is
  rejected with HTTP 403, `Content-Type: application/json; charset=utf-8`,
  `X-PDSH-Proxy-Error: mcp_egress_forbidden`, and body
  `{"error":{"code":"mcp_egress_forbidden","message":"the MCP egress credential is missing or invalid"}}`.
  No credential is resolved or injected, no socket is opened and no response-log
  entry is written. The header name is case-insensitive; the value is
  byte-exact and case-sensitive. On success the existing `x-pdsh-*` request
  strip removes the header before the upstream request.
- **User connector routes are covered.** WPF0 measured the real
  `PhoneMCPAccessSettings` -> `MCPEgressPolicy` -> `PhoneMCPCredentialProvider`
  -> `ModelGateway` chain: a Worker-shaped request to the user's exact
  connector route receives the stored connector header, and the real `curl`
  shim's request shape reaches the same route. A gate limited to the four Bot
  routes would leave the user connector credential injectable, so the gate uses
  the whole exact-route policy.
- **Secret handling.** The value never appears in logs, events, audit records,
  persisted settings, a response, or an upstream request. It is not persisted
  and not exported. Model-written bash, the `curl` shim, `git`, WASI Python and
  the PTC guest cannot read it: DSH's subprocess environment scrub removes names
  matching `/KEY|PASSWORD|SECRET|TOKEN/i`, and WP3 Q1 measured the existing
  token names absent from those surfaces. A future path that exposes the value
  is a contract violation: stop and report it; do not add a fallback header or
  a less-protected route.
- **Rotation.** One value per host start / loopback endpoint start. A Worker
  restart or engine rebuild inside the same host run does not rotate it; the
  host re-delivers the same value with the new Worker environment. A host
  restart or endpoint rotation invalidates the old value immediately and
  delivers the new one before reopening the Worker; until delivery every gated
  request fails closed with 403.
- **Placeholder semantics are preserved.** `PDSH_PHONE_MCP_TOKEN` remains the
  non-secret placeholder for the Bot bearer
  (`phone-host-injects-bot-mcp-token`) and for user connector host-managed
  headers (`phone-host-injects-mcp-key`). It is never accepted as an egress
  credential.

## 2. HTTP surface

- The listener binds IPv4 loopback only. No `.any` listener is allowed.
- Requests are `POST` only. `GET`, `DELETE` and every other method answer 405;
  `DELETE` never succeeds on any path.
- Paths are exact: `/mcp`, `/identity/register`, `/identity/cancel`,
  `/approval`. A query string, fragment, trailing slash, different case or a
  `..` segment is rejected (400) or not found (404); it is never normalized into
  a valid route.
- A request that carries `Origin` must carry exactly the listener's own origin.
  Requests without `Origin` (the host egress path) are accepted.
- `Authorization: Bearer <token>` is compared in constant time. Missing, wrong
  or previous tokens answer 401. A JSON request body is at most 1 MiB.
- After a `tools/call` attribution resolves a principal, the bare tool name
  must be present in the same per-caller catalog `tools/list` returns for that
  principal (`toolDefinitions(callerBotID: principal.botId)`). A Bot or team
  tool absent from that catalog is refused with `isError: true` and
  `structuredContent.error.code = "permission_denied"` before any effect or
  handler runs. An unknown name keeps `unknown_tool`; native forwarded tools
  keep native authorization; `CreateTeammate`'s main-Bot check remains a second,
  non-removable check. `tools/list` and `tools/call` use one caller resolution;
  the per-caller catalog is no longer only a display filter.
- **Long tool calls.** A single (non-batch) `tools/call` whose `Accept` lists
  `text/event-stream` and whose reply is not ready after 5 s is answered `200`
  `Content-Type: text/event-stream` (with `Mcp-Session-Id`, no `Content-Length`)
  at that moment, then the SSE comment `: keepalive` (one line, blank line) every
  15 s, then exactly one event `event: message` whose single `data:` line is the
  JSON-RPC response, then the connection closes. A reply ready within 5 s, any
  other method, a batch, a notification, or a client that does not accept
  `text/event-stream` keeps the unchanged `application/json` answer. This is MCP
  Streamable HTTP's SSE response form, which the Worker's client already reads;
  it keeps the host egress and the Worker delivery (each a 60 s idle limit) from
  failing a call that is still running. The call's overall bound stays the
  Worker's `toolCallTimeoutMs` (130 s). A keepalive carries no data and is never
  progress or a result; a connection that drops mid-stream leaves the call's
  receipt as the authority (native tools: [native-mcp.md](../../v1/native-mcp.md)).
  Shared cases: [golden/mcp-long-call/cases.json](../../v1/golden/mcp-long-call/cases.json).
- **Long approvals.** An interactive `/approval` waits for the user for up to
  the 300 s approval timeout, far longer than either 60 s idle limit. A
  `/approval` request whose `Accept` lists `text/event-stream` (the same
  explicit-media-type rule as long tool calls; `*/*` is not an SSE accept) and
  whose outcome is not ready after 5 s is answered with the same framing as a
  long tool call: `200` `Content-Type: text/event-stream` at that moment (no
  `Content-Length`, no `Mcp-Session-Id`), `: keepalive` every 15 s, then exactly
  one `event: message` whose single `data:` line is the unchanged approval
  outcome JSON object (`ok`, `allowed`, `approvalId`, `message`, `pending`,
  `expiresAt` as before), then the connection closes. An outcome ready within
  5 s (standing grants, durable `pending:true`, invalid requests) and a request
  without an explicit SSE accept keep the unchanged `application/json` answer.
  The Worker's approval client (`postApproval`, shared by `approval-gate` and
  `sandbox-approval`) sends `Accept: application/json, text/event-stream` and
  reads either form. In the stream form it accepts exactly one `event: message`
  with one `data:` line holding a JSON object; anything else (no message event
  before close, two message events, a non-JSON or non-object `data:`, another
  event name) is a transport failure and fails closed (`ok:false`, the tool call
  is not executed). The overall bound is unchanged: the App's 300 s approval
  timeout and the Worker's 330 s client timer. Shared cases: the `approval`
  block of [golden/mcp-long-call/cases.json](../../v1/golden/mcp-long-call/cases.json).
- `initialize` advertises the Bot server as `phone`; when a native forwarder is
  attached, native `instructions` are merged. `tools/list` returns the Bot
  catalog plus the native tools (Bot names win on collision). `tools/call`
  serves Bot tools through the Bot runtime and forwards every other tool to the
  native MCP handler unchanged. Native tools keep the native server's own
  authorization, receipts and cancellation semantics; they do not require Bot
  identity registration.

## 3. Identity and approval ordering

- **Session credential.** When the App issues a Bot session principal it also
  issues the registry's random session token (`BotTokenRegistry`, the same
  `dshg_` value the host keeps for that incarnation). It passes the token to
  the Worker in the `phone/botClaimSession` request as the new optional string
  field `sessionToken`; the Worker stores it in plugin memory for that session.
  The Worker's `identity-bridge` sends the stored value as `sessionToken` in the
  `/identity/register` body. The App resolves the principal from that token, not
  from the body `sessionId`, and requires
  `principal.sessionId == request.sessionId`. Missing, unknown, revoked,
  expired or mismatched credentials return HTTP 200 with
  `{"ok":false,"error":"unauthorized"}` and register nothing. The body
  `sessionId` is never identity evidence on its own.
- **`phone/botClaimSession` shape.** Request
  `{sessionId: string, sessionToken?: string}`; response remains
  `{ok: boolean, sessionId: string}`. The new request field is additive: an old
  Worker ignores it and an old App does not send it. The RPC remains a
  Worker-local ownership registration for the gates; it is not an authentication
  boundary by itself.
- **Worker-side lifetime.** The credential exists only in the Worker plugin's
  in-memory owned-session map; it is never an environment variable, a
  `/dsh/home` file, `UserDefaults`, Keychain, a BotEvent, a log entry or a UI
  notice. It is not written to the page URL. Only the host's
  `BotTokenRegistry` memory and that Worker map hold it.
- **Host lifecycle.** `issueSession` revokes the previous token for the session
  and issues a new one; the App re-claims the session after issue, re-sign,
  rotate or recovery. `revoke`, `revokeSession`, `revokeBot`, expiry and Bot
  deletion invalidate the token; the next registration fails closed. A Worker
  restart loses the in-memory credential, so the App must re-claim every active
  session with its current token before its next turn; until then registration
  fails closed. A foreground resume is a Worker restart for this rule: the host
  boots a fresh Worker page/worker process, the Worker answers a new HELLO with
  a new `boot_id`, and the App observes that boot-id change (the existing
  `.workerHello` host event) and re-claims every session it still owns. The App
  must not wait for a planned-restart/termination notification alone, and it
  must not extend the TTL to mask a missed re-claim. `gb-` ids are Bot-owned by
  namespace before the claim, but ownership alone does not authenticate: before
  a claim there is no credential, identity registration is rejected and the
  tool call fails closed, matching the existing "MCP catalog unreachable" rule.
  The Worker must not treat a `gb-` prefix, a tool name, an argument digest or a
  caller-supplied `sessionId` as a substitute for the credential.
- **Identity reclaim after a rejected registration.** A registration whose
  `sessionToken` is missing, stale or no longer the current incarnation answers
  `unauthorized` and registers nothing. Before that answer, the App may re-claim
  the session's current token into the Worker when, and only when, the App's
  own session credential map still holds a current token for the same
  `sessionId`. The Worker's one retry then reads the reclaimed token from its
  in-memory map and repeats the same registration. The reclaim path has these
  bounds:
  - The request body `sessionId` is never identity evidence; the App chooses
    the session from its own credential map, never from the caller.
  - A supplied token that resolves to a different session is an impersonation
    attempt, not a lost Worker map: it stays `unauthorized`, triggers no
    reclaim, and the Worker stays closed.
  - No token is returned in the HTTP response; the App re-claims through the
    existing `phone/botClaimSession` RPC carrying the App's current token.
  - The Worker retries at most once per registration. A second `unauthorized`
    ends the call closed and the model receives one human-readable sentence
    (the session/App identity is unavailable and the call did not execute),
    never a bare `unauthorized` and never a retry storm.
  - The same rule covers `unknownSession` from the host attribution registry;
    it maps to the same one `unauthorized` answer.
  - The App keeps the last failed registration (local time, error code and
    session id; no token, arguments or body) in host memory for the read-only
    Bot status line. A later successful registration clears it.
- The registration binds the incarnation of the token-resolved principal. The
  App must not re-resolve the session by `sessionId` between the token check and
  `registerToolCall` in a way that could bind a newer incarnation to an older
  credential; a rotation or revoke in that window fails the registration
  closed.
- The Worker registers a call before any structural approval request:
  registration runs on `tools/pre-execute` and the approval gate runs after it.
  Registration stays live through `tools/execute`, because the actual MCP
  `tools/call` and sandbox escalation arrive in that phase; the execute hook
  only cleans up.
- Cleanup is paired: an approval that is denied, a tool body that throws, an
  aborted call or an engine restart cancels the registration. A registration
  also expires after the approval window; it may not expire while its approval
  card is pending, so registration lifetime ≥ 300 s approval timeout.
- A cancelled registration ends its call's interactive approvals. When
  `/identity/cancel` removes a registration, the App cancels every
  **interactive** (non-durable) approval still pending for that registration's
  principal session and `callId` — structural and egress origin alike — exactly
  as `BotApprovalCoordinator.cancel(approvalId:)` already does: one
  `approval.decided` with `decision:"deny"`, `status:"cancelled"`,
  `reason:"consumer_cancelled"` (no new status or reason value), the card leaves
  the pending state, and any request still waiting on it is answered
  `{ok:false, allowed:false, message:"approval cancelled"}`. Durable approvals
  (`pending:true` todos) are never cancelled this way: their first attempt ends
  with a denied gate and a cancelled registration by design
  ([README §2.7](README.md)). The host
  egress keeps an upstream `/approval` request running after its Worker consumer
  went away (P05 response-log rule), so a dropped connection is not a
  cancellation signal; the Worker's paired `/identity/cancel` is.
- The App accepts registrations only for Bot tools, `bash`, `write`, `edit`,
  `phone` and the registered device tools. An unknown tool is answered
  `unknown_tool` and the Worker must not block unrelated built-ins on it.
- A claim binds the runtime generation, the bare tool name (an
  `mcp__<server>__` prefix is stripped on both ends), the argument digest and a
  still-current session principal incarnation. A registration for another tool
  or another generation can never be claimed or approved.

## 4. Worker restart

- `workerRestarted()` cancels every pending approval (closing each card as a
  cancelled `approval.decided` and appending a visible `ui.notice`), revokes
  every registration and rotates the registration generation. The Worker still
  sends the base runtime id (`phone-worker`); the App stores claims under
  `<runtimeId>@<generation>` and clears the previous generation.
- A Worker restart also loses every in-memory session credential. The App
  re-claims each active session with its current token before that session's
  next turn; a session that cannot be re-claimed fails identity registration
  closed. A background park followed by a foreground resume replaces the
  Worker exactly like a restart: the new HELLO `boot_id` is the observable
  trigger even though no planned-restart or termination event is sent. The App
  also re-claims every session it owns after that bind, so the first tool call
  after a lock screen does not race the claim. The MCP egress token is not
  rotated by a Worker restart (§1.1); the host re-delivers the same value
  through the rebuilt Worker environment.
- Expired registrations and their argument copies are pruned on registration,
  claim, approval and by a periodic maintenance task.
- Task records are durable SQLite events (`task.created`/`task.updated`, with
  the record fields unchanged for existing readers). A task that was running or
  stopping in the replaced Worker is reported as `status:"interrupted"` with
  `error:"worker_restarted"`; `AwaitTask` and `StopSubagent` return that record
  for the owning bot+chat session instead of `unauthorized`.
- Each interrupted asynchronous chat task wakes its parent exactly once. The
  wake marker is durable; the hidden-turn `session/prompt.requestId` is derived
  from the task id, so a crash between the turn and the marker cannot open a
  second turn.

## 5. Prompt idempotency

Held inbox deliveries, device deliveries, routine runs, task turns, parent
wakes and user-action turns derive `session/prompt.requestId` from the durable
delivery identity (inbox item ids, routine `runId`, task id, action nonce).
Replaying the same delivery therefore reuses the DSH dedupe key; a random id is
allowed only when the caller has no durable identity. `mode` remains
`queue`/`steer` with the existing semantics.

## 6. Compatibility

- The App and its Worker ship together. The supported security deployment is a
  new App with the new Worker; the mixed pairs below are recorded so a
  transitional build fails closed instead of silently claiming the fix.
- **New App + old Worker.** The old Worker's MCP clients send neither
  `X-PDSH-MCP-Egress` nor `sessionToken`. Every request to an exact MCP route is
  rejected at egress (the Bot tools, identity/approval and user connector
  mounts fail closed), and identity registration is rejected. A native-only
  configuration that never uses an exact MCP route is unchanged. This pair does
  not expose a credential and must not be described as fixed.
- **Old App + new Worker.** The old host does not validate either credential and
  keeps injecting the Bot/user credential, so the vulnerability remains. The new
  Worker's extra egress header is stripped by the existing `x-pdsh-*` rule; the
  extra `sessionToken` is ignored by the old `/identity/register`. No data is
  corrupted, but this pair is not a supported deployment for the fix.
- **New + new.** A/B/C are enforced: the exact-route gate, token-resolved
  identity and per-caller `tools/call` catalog check.
- **Persisted old data / rollback.** There is no persisted egress or session
  credential: both are per-host/per-Worker memory. Existing `/dsh/home/mcp.json`,
  BotEvent rows, session logs and the SQLite Bot store are unchanged. Rolling
  back to the old App or Worker restores the old (vulnerable) behavior without a
  data migration or a stale credential that a later build could reuse.
- **Android / HarmonyOS.** Neither has a Bot runtime; A/B/C are `not started`
  there and no `PDSH_MCP_EGRESS_TOKEN` is required. Non-Bot `/v1/http` and
  Worker-environment behavior is unchanged: a missing header on a non-MCP target
  is not an error. A future host that carries the Worker Bot runtime must
  implement this contract before claiming support.
- `tools/list` for a caller without a principal (a standard MCP client with no
  `x-pdsh-bot-session`) and native forwarded tools are unchanged; the
  `tools/call` catalog check applies only after attribution.
- No new HTTP route, JSON-RPC method, schema file or wire frame is introduced.
  The two additive fields are `sessionToken` in the existing
  `phone/botClaimSession` request and `/identity/register` body; the new Worker
  environment variable is P16's `PDSH_MCP_EGRESS_TOKEN`; the new hop header is
  `X-PDSH-MCP-Egress`; the new egress error code is `mcp_egress_forbidden`.
- **Identity reclaim (PC-20261111-bot-identity-reclaim).** Reclaim adds no
  field, route, method, header or error code: it reuses the existing
  `phone/botClaimSession` RPC and the existing `unauthorized` answer, and the
  Worker's retry sends the same `/identity/register` body. An old Worker that
  does not retry still gets the re-claimed credential for its next registration;
  an old App that does not re-claim leaves the new Worker's retry closed. The
  new host boot-id observation is an in-process consumer of the existing
  `.workerHello` event; no host-event shape changes.
- **Long tool calls (§2).** The SSE answer to a long `tools/call` is the
  response form MCP Streamable HTTP already defines and the Worker's MCP client
  already reads (it sends `Accept: application/json, text/event-stream`); it adds
  no field, header, error code or wire frame. A client that does not accept
  `text/event-stream`, and every call answered within 5 s, keep the unchanged
  `application/json` answer; an older listener answers JSON as before, so a
  long call there still meets the 60 s idle limits.
- **Long approvals (§2) and cancel cascade (§3)**
  (PC-20261112-bot-approval-keepalive). New App + old Worker: the old
  `postApproval` sends no SSE accept, gets JSON, and a card left longer than 60 s
  still fails the call with `PDSH_DELIVERY_TIMEOUT`; the cascade still closes
  that card when the old Worker's paired `/identity/cancel` arrives. Old App +
  new Worker: the old listener ignores `Accept` and answers JSON, which the new
  client still reads; no cascade, so the zombie card remains until the 300 s
  timeout as before. New + new: the wait is bounded only by the approval
  timeout, and a call that ends early closes its card. No route, field, header,
  status, reason or error code is added; no persisted data changes and rollback
  needs no migration.
- Native-only configurations keep the pre-existing `/mcp/native` environment.
  An older App that still writes `/mcp/native` into the Worker environment is not
  affected by this contract; a newer App paired with this Worker forwards native
  tools through the Bot endpoint. Both ends are expected to upgrade together,
  and no old Worker is asked to understand a new field.
- Task status `interrupted` is an additive string value inside the existing
  free-form `task.*` event data; consumers that do not know it already render an
  unknown task status conservatively.

## 7. JSON-RPC surface

Status: `implemented` on the Swift end (`BotMCPHandler`, `BotMCPHTTPServer`); Kotlin is `not started`.
D13 of `docs/design/android-bot-spec-deltas.md` is the proposal; where it differs from the frozen
text below, this section and the shared fixtures are authoritative and the difference is recorded in
`docs/protocol-changes/PC-20261113-bot-mcp-d13.md`.

This section freezes the JSON bodies carried by `/mcp`. It does not add a transport: the framing is
MCP Streamable HTTP as already fixed by §2. The `jsonrpc` member is accepted but not validated
(`BotMCPHTTPServer.respond`, `BotMCPHandler.rpc`); a message is a request iff its `id` member is
present, including `"id": null` (`BotMCPHTTPServer.swift:477-510`).

### 7.1 `initialize`

- `params` is optional; `params.protocolVersion` is optional. A requested version equal to
  `"2025-11-25"`, `"2025-06-18"` or `"2025-03-26"` is echoed byte-for-byte; every other value,
  including a missing or non-string value, selects the first entry, `"2025-11-25"`
  (`BotMCPHandler.swift:17`, `:46-56`).
- The result is exactly
  `{"protocolVersion": <selected>, "capabilities": {"tools": {}}, "serverInfo": {"name": "phone", "version": "1.0.0"}}`.
  No `resources`, `prompts`, `logging` or experimental capability is advertised.
- When a native forwarder is attached and its `initialize` result contains a non-empty
  `instructions` string, the Bot result gains `"instructions": <native instructions>`. No other
  native result member is merged and a native error or absent result is silently ignored
  (`BotMCPHandler.swift:52-55`, `:220-235`).
- `initialize` has no session precondition, is not attributed and never creates state.

### 7.2 `ping`

The result is the empty object `{}` (`BotMCPHandler.swift:57`). `params` is ignored. `ping` never
consults identity, the catalog or the native forwarder.

### 7.3 `tools/list`

- The result is `{"tools": [{"name", "description", "inputSchema"}, ...]}`. Each entry is the
  JSON encoding of `BotMCPToolDefinition` with sorted keys (`BotMCPHandler.swift:58-73`,
  `BotMCPTypes.swift:5-15`). No `nextCursor` is emitted.
- Caller resolution: the optional request header `x-pdsh-bot-session` (case-insensitive name,
  surrounding whitespace trimmed, empty treated as absent) is the App-minted MCP session id. The
  value is resolved through the same token registry as `tools/call` attribution; an unknown,
  revoked, expired or empty value yields the static catalog
  (`BotMCPHandler.swift:21-24`, `:296-304`; `BotMCPRuntime.swift:554-571`).
- With a resolved caller the list is `toolDefinitions(callerBotID:)`: the P0 catalog plus
  `FishAction`, `BotVolatileContext` and the team tools, minus `CreateTeammate` for a non-main Bot.
  A standard MCP client without the header keeps the static catalog.
- Native tools are appended after every Bot tool, in the native server's order. A native tool is
  included only when its `name` does not already occur in the Bot list; the Bot entry wins on
  collision. Duplicate native names are likewise included once. Native order is not otherwise
  changed and the combined list is not re-sorted (`BotMCPHandler.swift:58-73`, `:209-218`).
- A `tools/list` encoding failure is JSON-RPC error `-32603` with message
  `"tool catalog encoding failed"` (`BotMCPHandler.swift:72`).
- This method is read-only: it never registers, approves, mutates a grant or writes an event.

### 7.4 `tools/call`

- `params` MUST be an object with a string `name`. A missing or non-string name is JSON-RPC error
  `-32602` with `"tools/call requires name"`. `arguments` defaults to `{}` and MUST be an object
  when present, else `-32602` with `"arguments must be an object"`
  (`BotMCPHandler.swift:74-82`).
- The bare name strips a leading `mcp__<server>__` by taking the last `__`-separated component
  (`mcp__phone__ask_user` -> `ask_user`; `mcp__a__b__c` -> `c`) (`BotMCPHandler.swift:280-283`).
  Both ends strip the same way; a call is registered and approved under the bare name.
- Dispatch order (`BotMCPHandler.swift:83-101`):
  1. A registered Bot tool (`BotToolCatalog.isRegistered`: the 17 P0 names plus
     `BotVolatileContext`) or a host-registered team tool runs in the Bot runtime.
  2. Every other name is forwarded to the attached native forwarder with the original
     `id`, `params` and HTTP headers. A native `error` or `result` is returned unchanged under the
     Bot response envelope.
  3. If no forwarder claims the name, the result is the Bot failure result
     `unknown_tool`: `content: [{"type": "text", "text": "Unknown tool: <bare>"}]`,
     `structuredContent: {"ok": false, "error": {"code": "unknown_tool", "message": "Unknown tool: <bare>"}}`,
     `isError: true` (`BotMCPTypes.swift:52-60`; `BotMCPHandler.swift:86-96`).
- The result of a Bot tool is the `BotMCPCallResult` shape (`BotMCPTypes.swift:39-68`):
  `content` is always present and is an array of content blocks; the canonical success/failure
  block is `{"type": "text", "text": <string>}`. `structuredContent` is present for every Bot tool
  result. `isError` is omitted for success and is exactly `true` for a failure. A failure result's
  `structuredContent` is `{"ok": false, "error": {"code": <code>, "message": <message>}}` and its
  text block carries the same human message. There is no other error channel inside a `tools/call`
  result; the JSON-RPC `error` member is reserved for the framing failures in §7.5.
- Default text: a success whose handler does not supply custom text sets `content[0].text` to the
  canonical JSON encoding of `structuredContent` (sorted keys, `/` unescaped). `ask_user` and
  `show_next_steps` use the fixed sentences in `cards.md` §7; `RequestApproval` uses the summary
  required by `tool-contracts.md` §7. A client MUST treat `content` as display text and
  `structuredContent` as the machine result.
- The per-caller catalog is enforced after attribution and before any effect: a name present in the
  Bot catalog but absent from `toolDefinitions(callerBotID: principal.botId)` fails with
  `permission_denied` and no handler runs (§2; `BotMCPRuntime.swift:1274-1284`). An unknown name
  stays `unknown_tool`; native names keep native authorization (`CreateTeammate`'s main-Bot check
  remains an additional check).
- Before dispatch, the runtime removes the claimed registration and its argument copy; a second
  `tools/call` with the same id therefore needs a new registration
  (`BotMCPRuntime.swift:1285-1287`). A missing registration yields `unattributed`
  (`:1268-1272`).

### 7.5 Errors, batches and notifications

- JSON-RPC error codes used by the Bot endpoint:
  | code | meaning | messages (exact) |
  | --- | --- | --- |
  | `-32601` | method not found and no native forwarder | `method not found: <method>` |
  | `-32602` | invalid `tools/call` params / unknown tool with no forwarder and no encodable failure | `tools/call requires name`, `arguments must be an object`, `unknown tool: <bare>` |
  | `-32603` | internal encoding failure | `tool catalog encoding failed`, `tool result encoding failed` |
- An unknown method is forwarded to the native forwarder first; only when no forwarder produces a
  response is `-32601` returned (`BotMCPHandler.swift:103-109`). Native errors are returned verbatim
  and are not remapped.
- A single JSON object request is answered with one JSON object. A JSON array is a batch: each
  element MUST be an object with a string `method`, otherwise the whole request is answered
  HTTP 400 with `{"error":"invalid JSON-RPC message"}` and no reply is produced for any element.
  Replies keep request order; elements without an `id` are notifications and produce no reply
  (`BotMCPHTTPServer.swift:477-511`).
- A batch containing only notifications is answered `202` with an empty body and the
  `Mcp-Session-Id` header. A batch with at least one request is answered `200` with a JSON array of
  exactly the replies for the requests, in request order. A single request keeps the `200` object
  form; an array body always gets an array reply, including an array of length one.
- Notifications are not forwarded to native, never create identity/approval state and are never
  answered with a JSON-RPC error. JSON-RPC-level validation of `jsonrpc`, `method` prefixes or
  unknown `params` members does not exist; the HTTP framing checks above are the only envelope
  validation.

### 7.6 Native forwarding (including the `/mcp/native` limitation)

- A forwarder is optional and replaceable. `initialize` merges native `instructions` only (§7.1);
  `tools/list` appends undeclared native names only (§7.3); `tools/call` forwards a non-Bot name
  unchanged with the original headers; any other method is forwarded before `-32601` is chosen
  (`BotMCPHandler.swift:195-235`). The native server keeps its own authorization, idempotency
  receipts, timeout and cancellation semantics; the Bot endpoint adds no second check for a
  forwarded call.
- Forwarded requests carry the Bot listener's HTTP headers unchanged, including
  `X-PDSH-Idempotency-Key`; the Bot listener does not rewrite, add or drop one.
- **GAP-36 is frozen as a known failure, not hidden.** `/mcp/native` (`NativeMCPServing`) answers
  one buffered JSON body and has no SSE form. A native tool call made directly against
  `/mcp/native` that runs longer than the 60 s idle limits on that path still fails; the same call
  through the Bot listener streams after 5 s (§2) and does not. Only a native-only configuration
  uses `/mcp/native` as the Worker's `phone` server. Implementations MUST NOT lengthen the idle
  limits, claim SSE support on `/mcp/native`, or move this limitation into a comment instead of
  this clause.

## 8. Identity and approval bodies

Status: `implemented` on the Swift end; Kotlin is `not started`. All four routes keep the §2
transport rules (POST only, exact path, origin, bearer, 1 MiB). Every route answers HTTP 200 with a
JSON object for a syntactically valid JSON body, including application-level refusals; HTTP status
is reserved for the transport failures in §11.

### 8.1 `/identity/register`

Request body (`BotMCPHandler.swift:112-155`):

| member | type | required | meaning |
| --- | --- | --- | --- |
| `runtimeId` | string | yes | MUST equal the handler's runtime id, `phone-worker` |
| `sessionId` | string | yes | the session the caller claims; **not identity evidence** |
| `callId` | string | yes | the model tool-call id shared with `/approval` |
| `name` | string | yes | tool name; a leading `mcp__<server>__` is stripped |
| `arguments` | any JSON | no | default `{}`; the digest is computed from its canonical encoding |
| `argsDigest` | string | no | 64 lowercase hex; when present with `arguments`, the body digest MUST match |
| `sessionToken` | string | no | the App-issued `dshg_` credential |

- A missing/wrong-typed required member, or `runtimeId` different from `phone-worker`, answers
  `{"ok":false,"error":"invalid identity registration"}` and registers nothing
  (`BotMCPHandler.swift:113-120`).
- A missing or empty `sessionToken` answers `{"ok":false,"error":"unauthorized"}` and registers
  nothing; the App's one reclaim retry (§3) may run before that answer
  (`BotMCPHandler.swift:126-139`).
- The token resolves the principal. A missing, unknown, revoked, expired, malformed (>512 bytes),
  or different-session token is one `unauthorized` answer. `principal.sessionId` MUST equal the
  body `sessionId`; the body value never replaces the token lookup
  (`BotMCPRuntime.swift:781-820`; `BotTokenRegistry.swift:129-168`).
- When `argsDigest` is present together with `arguments`, a mismatch between the supplied digest and
  `SHA-256(canonical JSON(arguments))` answers
  `{"ok":false,"error":"argument digest mismatch"}` before any registration
  (`BotMCPHandler.swift:141-148`). When `argsDigest` is absent the runtime computes it from
  `arguments`; when `arguments` is absent but `argsDigest` is present the supplied digest is
  validated and stored (`BotMCPRuntime.swift:708-757`).
- The bare tool name MUST be one of: the 17 P0 names plus `BotVolatileContext`; `bash`, `write`,
  `edit`, `phone`; a host-registered device tool; or a host-registered team tool. Any other name
  answers `{"ok":false,"error":"unknown_tool"}` (`BotMCPRuntime.swift:713-723`).
- Success is `{"ok":true,"id":"<32 lowercase hex>"}`, where `id` is the attribution id used by
  `/identity/cancel`. A repeat registration with the same runtime generation, session, call id,
  tool and digest refreshes the existing entry instead of publishing a duplicate
  (`BotMCPRuntime.swift:724-745`).
- Error strings are exactly: `invalid identity registration`, `unauthorized`,
  `argument digest mismatch`, `unknown_tool`, `invalid_request`, `unattributed`,
  `cross_session_denied`, `timeout`, `unavailable`, `identity registration refused`
  (`BotMCPHandler.swift:273-286`; the last is the catch-all for a non-`BotMCPError` failure).
  `identity registration refused` is not an enum value of its own; it is the fallback sentence.
- A rotation or revoke between token resolution and registration fails closed: the gateway
  re-reads the current incarnation before and after publishing the attribution
  (`BotGateway.swift:72-96`). No registration survives it.

### 8.2 `/identity/cancel`

- Body `{"id": <string>}`. A valid id answers `{"ok": true}` only when both the local registration
  and the gateway entry were cancelled; an unknown id, an already-removed gateway entry, a
  non-object body or a non-string `id` answers `{"ok": false}` (`BotMCPHandler.swift:157-162`; `BotMCPRuntime.swift:837-853`).
- A successful cancel also cancels every **interactive** approval pending for that registration's
  principal session and `callId` — one `approval.decided` with `decision:"deny"`,
  `status:"cancelled"`, `reason:"consumer_cancelled"` and the waiting request answered
  `{ok:false,allowed:false,message:"approval cancelled"}`. Durable (`pending:true`) approvals are
  never cancelled this way (§3; `BotMCPRuntime.swift:842-851`;
  `BotApprovalCoordinator.swift:581-593`).
- A dropped `/approval` connection is not a cancellation signal; only this route (or a Worker
  restart, §4) cancels.

### 8.3 `/approval`

Request body (`BotMCPHandler.swift:164-187`):

| member | type | required | default / rule |
| --- | --- | --- | --- |
| `sessionId` | non-empty string | yes | narrows the registration lookup; the principal's session must match |
| `callId` | string | yes | the registered call id |
| `tool` | string | yes | bare or `mcp__<server>__`-prefixed; both ends strip |
| `argsDigest` | string | yes | 64 hex, case-insensitive, compared to the registration digest |
| `alwaysScope` | string | yes | `until`, `session` or `none` (§8.4) |
| `action` | string | no | defaults to `tool`; human label on the card |
| `detail` | string | no | default `""` |
| `command` | string | no | default `""`; for `bash` it MUST equal the registered `arguments.command` |
| `effects` | array | no | only used by a sandbox escalation; malformed entries are dropped |
| `askAction` | string | no | default `"tool-call"`; `"sandbox-escalation"` selects §8.4 |

- A body missing any required member or carrying an empty `sessionId` answers
  `{"ok":false,"allowed":false,"message":"invalid approval request"}`. The response object always
  contains `ok`, `allowed` and `pending` (a boolean; `false` for every interactive outcome). It
  gains `approvalId`, `message`, `expiresAt`, `approvalDecision` and `scope` only when defined
  (`BotApprovalCoordinator.swift:5-56`).
- Validation order and exact refusal messages (`BotMCPRuntime.swift:937-995`):
  1. A registration that is missing, expired, from another Worker generation, from another
     session, registered under another tool, or whose principal incarnation is no longer current is
     `unattributed`. Exactly one live registration must match the scoped runtime and `callId`
     (`BotMCPRuntime.swift:855-875`).
  2. A malformed supplied digest, or a digest different from both the registration digest and the
     digest of the stored arguments, is `stale:digest_mismatch`.
  3. For `bash`, a `command` different from the registered `arguments.command` is
     `stale:command_mismatch`. The comparison is exact string equality.
  4. A Task-session authorization denial is one of `task_scope:missing_authorization`,
     `task_scope:path_denied` (see `tool-contracts.md` §4) and is returned before a card exists.
  5. A malformed sandbox escalation is `stale:sandbox_effect` (§8.4).
  6. An `alwaysScope` outside the enum, or different from the expected scope (§8.4) and not
     `none`, is `stale:always_scope`.
  7. When the computed effect set is empty the call is auto-allowed with
     `{"ok":true,"allowed":true,"pending":false,"message":"auto-policy"}`; no card is created.
- Decision outcomes:
  | decision | response |
  | --- | --- |
  | allow once | `ok:true, allowed:true, pending:false, approvalId, message:"allowed", approvalDecision:"allowOnce", scope:"once"` |
  | always + `until` | same but `approvalDecision:"always", scope:"until"` |
  | always + `session` | same but `approvalDecision:"always", scope:"session"` |
  | always + `none` | same but `approvalDecision:"always", scope:"once"` (the effective grant is one-shot) |
  | deny | `ok:false, allowed:false, pending:false, approvalId, message:"approval denied", approvalDecision:"deny"`; no `scope` |
  | interactive timeout | `ok:false, allowed:false, pending:false, approvalId, message:"approval timed out"`; no decision or scope |
  | consumer cancel | `ok:false, allowed:false, pending:false, approvalId, message:"approval cancelled"` |
  | durable pending | `ok:true, allowed:false, pending:true, approvalId, message:"approval pending", expiresAt` |
  (`BotApprovalCoordinator.swift:414-506`, `:953-970`).
- The `once` grant is consumed atomically at decision time for an interactive approval unless
  every effect declares an `execution` seam, in which case consumption is deferred to execution.
  A durable approval never consumes at decision time; its once grant is consumed by the resumed
  retry, and a second concurrent consumer gets a closed failure
  (`BotApprovalCoordinator.swift:289-300`, `:455-470`).

### 8.4 effect set, expected scope and sandbox escalation

- The effect set is derived by the App from the registered tool and arguments, not from the body:
  `BotVolatileContext` yields no effect; `bash` uses the frozen destructive-command patterns;
  `write`/`edit` use directory-granular file effects inside/outside the Bot workspace; other tools
  use `BotToolEffectClassifier`. A read/UI/auto effect yields no card; a write/ask or unknown effect
  yields one (`BotMCPRuntime.swift:1973-1998`; `BotToolEffects.swift:56-225`).
- Expected scope is `"until"` when the effect set is non-empty and at least one effect has
  `known:true`; it is `"session"` when every effect has `known:false`. An `alwaysScope` of `"none"`
  is accepted for every tool and resolves an `always` decision to a one-shot grant. Otherwise the
  supplied scope MUST equal the expected scope (`BotMCPRuntime.swift:984-992`). This is the frozen
  Swift rule; D13's narrower reading (`none` only for sandbox escalation) is superseded here.
- Sandbox escalation (`askAction:"sandbox-escalation"`) requires: bare tool `bash`,
  `alwaysScope:"none"`, exactly one body effect whose `operation` is `"sandbox-escalation"` and
  whose normalized `resource` is non-empty. The App replaces tool/operation/mutability/policy with
  `bash` / `sandbox-escalation` / `write` / `ask`, takes `label` from `action`, `detail` from
  `detail`, and `target` from the body effect. A violation is `stale:sandbox_effect`
  (`BotMCPHandler.swift:179-186`, `:282-304`; `BotMCPRuntime.swift:963-975`).
- An interactive card is pending for 300,000 ms. Expiry writes one `approval.decided` with
  `decision:"deny"`, `status:"denied"`, `timedOut:true`, closes the card and answers the waiter
  `approval timed out` (`BotApprovalCoordinator.swift:202-205`, `:953-970`). A durable todo expires
  after 24 h with `status:"expired"`, `reason:"approval_expired"`, `expired:true`,
  `timedOut:false`; its waiter gets `approval expired`
  (`BotApprovalCoordinator.swift:205`, `:916-951`).

## 9. Session credentials and attribution

Status: `implemented` on the Swift end; Kotlin is `not started`. §3 owns the ordering and the
Worker-side lifetime; this section freezes the registry limits and the attribution tuple.

### 9.1 Session credential registry

- **Token.** `dshg_` + unpadded URL-safe Base64 of 32 bytes from `SystemRandomNumberGenerator`
  (`A-Za-z0-9-_`, 43 characters, 48 total). The raw token is returned only to the in-process
  caller of `issueSessionToken`; the registry stores only `SHA-256(token)` and compares digests in
  constant time. Token lookups accept at most 512 UTF-8 bytes and reject the empty token
  (`BotTokenRegistry.swift:119-127`, `:129-151`, `:267-276`).
- **Incarnation.** 16 random bytes as 32 lowercase hex characters, regenerated on every issue and
  rotate; it is never reused. It is not a secret and grants no authority by itself
  (`BotTokenRegistry.swift:120`, `:31-50`).
- **TTL and capacity.** Default TTL 12 h (43,200,000 ms); `expiresAt = now + ttl`, overflowing or
  non-positive expiry is rejected. At most 4,096 live records after pruning; the next issue fails
  with `registryFull`. `prune` removes expired records (`BotTokenRegistry.swift:57-58`, `:98-117`,
  `:238-241`).
- **Issue per session.** `issueSession(botId:sessionId:kind:)` first revokes every existing token
  for that session, then issues one token, so a session has one current incarnation. `issue`
  alone does not revoke; the host's session-claim path MUST use `issueSession`/`issueSessionToken`
  (`BotTokenRegistry.swift:87-96`).
- **Lookup.** `lookup(token)` returns the principal of the unique unexpired record; an expired
  record is removed. `lookupSession(sessionId)` returns the record whose incarnation is the current
  one for that session. `lookupBearer` accepts exactly two whitespace-separated fields with a
  case-insensitive `Bearer` scheme (the MCP listener's own bearer check is separate and stricter,
  §11) (`BotTokenRegistry.swift:129-168`).
- **Revocation and rotation.** `revoke(token)` removes one; `revokeSession` removes all records of
  a session; `revokeBot` removes all records of a Bot; `rotate(token, capabilities?, expiresAt?,
  ttl?)` issues a replacement with the same bot/session/kind, the new token and incarnation, keeps
  the old expiry unless `expiresAt`/`ttl` is given, then removes the old record. An unknown or
  expired token rotates to `nil`. Every revoke/rotate immediately invalidates registrations that
  bound the old incarnation (`BotTokenRegistry.swift:192-236`).
- The token, digest and incarnation are memory-only: never an environment variable, `/dsh/home`
  file, `UserDefaults`, Keychain, BotEvent, log or UI notice (§3). A Worker restart loses the
  Worker copy; the App re-claims the current token (§4).

### 9.2 Attribution registration

- **TTL and capacity.** Default TTL = approval timeout + 30,000 ms = 330,000 ms; at most 4,096
  entries. Expired entries are pruned on registration, claim, approval lookup and by the runtime's
  30 s maintenance task (`BotAttributionRegistry.swift:42-43`; `BotMCPRuntime.swift:231`, `:360-366`,
  `:917-935`).
- **Registration tuple.** `(scopedRuntimeId, sessionId, callId)` is the key; the stored value also
  binds `incarnation`, bare `name`, `argsDigest`, unscoped `runtimeId`, `createdAt`, `expiresAt`.
  `scopedRuntimeId` is `<runtimeId>@<generation>`; the Worker always sends `phone-worker` and the
  generation starts at 0 (`BotMCPRuntime.swift:704-706`, `:877-903`).
- **Duplicate rule.** The registry rejects a second entry with the same session, incarnation,
  digest, name and runtime id as `duplicate`. The runtime normally intercepts this case first and
  refreshes the existing entry, returning the same `id`
  (`BotAttributionRegistry.swift:91-103`; `BotMCPRuntime.swift:724-745`).
- **Valid names.** The same set as §8.1: P0 + `BotVolatileContext`, `bash`/`write`/`edit`/`phone`,
  device tools and handled team tools. Anything else is `unknownTool` and no entry is written.
- **Lifetime in the call.** The Worker registers on `tools/pre-execute`; the entry stays live
  through `tools/execute` because the actual `tools/call` and a sandbox escalation arrive there.
  The execute hook cleans up; the runtime also removes the entry when it resolves the call at the
  start of execution. A denied approval, a throwing body, an aborted call and an engine restart all
  cancel the registration (§3; `BotMCPRuntime.swift:837-853`, `:1285-1287`).
- **Claim.** `identityForApproval` requires exactly one live entry for the scoped runtime and
  `callId` (narrowed by `sessionId` when supplied), `expiresAt > now`, and a current principal
  incarnation. Zero or many matches are `unattributed`. The bare tool name and the digest are
  checked again by `/approval`; a registration for another tool, another session or another
  generation can never be claimed or approved (`BotMCPRuntime.swift:855-875`, `:944-960`).
- **Generation.** `workerRestarted()` cancels every pending interactive card, removes every
  registration, cancels the gateway entries for the previous scoped runtime, increments the
  generation and rebuilds durable approvals from the log. Entries from the previous generation can
  never be claimed (`BotMCPRuntime.swift:877-903`).
- `x-pdsh-bot-session` is not a registration and never authorizes `tools/call`; it only selects the
  `tools/list` catalog (§7.3).

## 10. Listener recovery

Status: `implemented` on the Swift end; Kotlin is `not started`.

- The listener binds IPv4 loopback only and starts on an ephemeral port. `ensureListening()` first
  probes the current endpoint with a TCP connect bounded by 1.5 s; if it succeeds the endpoint is
  unchanged (`BotMCPHTTPServer.swift:121-143`, `:340-368`).
- On a failed probe or an unexpected listener `.failed`/`.cancelled`, the old listener is cancelled
  and the previous port is tried up to two times with 100 ms between attempts. If it cannot be
  rebound, a new ephemeral port is bound. A URL change is published through `onEndpointChange`
  before the new endpoint is used (`BotMCPHTTPServer.swift:145-216`, `:218-260`).
- Every Worker start/resume path heals the listener before reading its URL. A listener that only
  observed `.ready`/`.failed` once is not sufficient: iOS may reap the socket while the process
  lives (`BotMCPHTTPServer.swift:29-45`).
- The listener bearer is fixed for the lifetime of the `BotMCPHTTPServer` instance. A rebind on the
  same host does **not** rotate it; a Worker restart reuses the same instance and therefore the same
  value; a host restart creates a new instance and a new random token
  (`BotMCPHTTPServer.swift:44-80`, `:590-594`). The P16 egress token follows the same host-start
  rule (§1.1). The new URL and token are delivered to the rebuilt Worker before its next turn.
- A probe is a liveness check only: it carries no HTTP request, no bearer and no MCP message, and
  it never counts as a tool call or an approval.

## 11. HTTP limits and error forms

Status: `implemented` on the Swift end; Kotlin is `not started`. §2 owns the rules; this table
freezes the exact byte forms so a second implementation does not invent near-miss bodies.

| condition | status | body (exact) |
| --- | --- | --- |
| `Origin` present and not the listener origin (case-insensitive comparison) | 403 | `{"error":"origin mismatch"}` |
| missing, wrong, case-shifted or previous `Authorization` value | 401 | `{"error":"unauthorized"}` |
| method other than `POST` (including `GET`, `DELETE`, `PUT`) | 405 | `{"error":"method not allowed"}` |
| empty target, query string, fragment, `..` segment, or a target not starting with `/` | 400 | `{"error":"invalid request target"}` |
| exact path not one of the four routes (`/mcp`, `/identity/register`, `/identity/cancel`, `/approval`) | 404 | `{"error":"not found"}` |
| `Content-Length` greater than 1,048,576, or a read that exceeds 1,048,576 + 65,536 bytes | 413 | `{"error":"request too large"}` |
| body is not valid JSON | 400 | `{"error":"invalid JSON"}` |
| a batch element is not an object with a string `method` | 400 | `{"error":"invalid JSON-RPC message"}` |
| `/mcp` body contains only notifications | 202 | empty body |
| any valid route result | 200 | the JSON object/array from §7-§8 |

- `Authorization` is compared as the whole UTF-8 byte string against `"Bearer <token>"` in
  constant time; the scheme is case-sensitive, the token is byte-exact, and a trailing space is a
  different value (`BotMCPHTTPServer.swift:437-441`, `:577-588`).
- Every JSON answer sets `Content-Type: application/json`, `Content-Length` and
  `Connection: close`. `/mcp` JSON answers and the SSE answer to a long `tools/call` carry
  `Mcp-Session-Id`; `/approval` never carries it; the `/approval` SSE answer is
  `text/event-stream` with no `Content-Length` (§2; `BotMCPHTTPServer.swift:519-565`).
- The body limit is 1,048,576 bytes (`BotMCPHTTPServer.maximumBodyBytes`). The
  `+65,536` transport read headroom exists only to return the 413 instead of closing a socket;
  it is not a second accepted limit (`BotMCPHTTPServer.swift:45`, `:378-390`, `:414-419`).
- The check order is origin -> bearer -> method -> target -> JSON parse -> route. A request failing
  several checks gets only the first one in that order; an application refusal from
  `/identity/*` or `/approval` is always HTTP 200.
- Paths are never normalized: `/mcp/` is 404, `/MCP` is 404, `/mcp?x=1` is 400, and
  `/identity/../mcp` is 400. `DELETE` never succeeds on any path (§2).
