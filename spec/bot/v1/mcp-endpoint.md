<!-- SPDX-License-Identifier: MIT -->

# Bot MCP endpoint, identity and restart contract (Bot v1)

Status: normative for the App/Worker `phone` MCP endpoint introduced by the Bot
runtime. Contracts: P05 (HTTP/MCP gateway), P16 (Worker environment), P25
(BotEventLog), P26 (BotToolSurface).

This document is the owning contract for the single `phone` MCP endpoint the
Worker sees. It does not define a new transport: it reuses MCP Streamable HTTP,
the existing Bot JSON-RPC messages and the existing BotEvent log.

## 1. One owner for the Worker environment

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
- `initialize` advertises the Bot server as `phone`; when a native forwarder is
  attached, native `instructions` are merged. `tools/list` returns the Bot
  catalog plus the native tools (Bot names win on collision). `tools/call`
  serves Bot tools through the Bot runtime and forwards every other tool to the
  native MCP handler unchanged. Native tools keep the native server's own
  authorization, receipts and cancellation semantics; they do not require Bot
  identity registration.

## 3. Identity and approval ordering

- The Worker registers a call before any structural approval request:
  registration runs on `tools/pre-execute` and the approval gate runs after it.
  Registration stays live through `tools/execute`, because the actual MCP
  `tools/call` and sandbox escalation arrive in that phase; the execute hook
  only cleans up.
- Cleanup is paired: an approval that is denied, a tool body that throws, an
  aborted call or an engine restart cancels the registration. A registration
  also expires after the approval window; it may not expire while its approval
  card is pending, so registration lifetime ≥ 300 s approval timeout.
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

- No new HTTP route, JSON-RPC method, environment variable or wire frame is
  introduced. `tools/list` gains the native tools only when the App attaches a
  native forwarder; a Bot-only deployment is unchanged.
- Native-only configurations keep the pre-existing `/mcp/native` environment.
- An older App that still writes `/mcp/native` into the Worker environment is
  not affected by this contract; a newer App paired with this Worker forwards
  native tools through the Bot endpoint. Both ends are expected to upgrade
  together, and no old Worker is asked to understand a new field.
- Task status `interrupted` is an additive string value inside the existing
  free-form `task.*` event data; consumers that do not know it already render an
  unknown task status conservatively.
