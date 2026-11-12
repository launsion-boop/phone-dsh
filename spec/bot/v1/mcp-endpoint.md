<!-- SPDX-License-Identifier: MIT -->

# Bot MCP endpoint, identity and restart contract (Bot v1)

Status: normative for the App/Worker `phone` MCP endpoint introduced by the Bot
runtime. Contracts: P05 (HTTP/MCP gateway), P16 (Worker environment), P25
(BotEventLog), P26 (BotToolSurface). Contract revision:
`mcp-egress-capability-v1` (PC-20261110-bot-mcp-egress-capability).

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
  fails closed. `gb-` ids are Bot-owned by namespace before the claim, but
  ownership alone does not authenticate: before a claim there is no credential,
  identity registration is rejected and the tool call fails closed, matching the
  existing "MCP catalog unreachable" rule. The Worker must not treat a
  `gb-` prefix, a tool name, an argument digest or a caller-supplied
  `sessionId` as a substitute for the credential.
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
  closed. The MCP egress token is not rotated by a Worker restart (§1.1); the
  host re-delivers the same value through the rebuilt Worker environment.
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
