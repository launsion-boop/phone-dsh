# Bot MCP listener recovery and loopback fast-fail

```yaml
change: PC-20261110-bot-mcp-listener-recovery
contracts: [P05, P26, P27]
status: implemented
breaking: false
version_decision: No version change. The MCP methods, JSON-RPC/HTTP envelopes, token, routes, Worker variables and gateway error shapes are unchanged; only the liveness of the App-owned loopback listener and the timeout policy for loopback upstreams change.
base: 451b98cc9
contract_revision: none (no owning spec, schema or golden change)
```

Protocol impact: P05; P26; P27. P25: none — no event-envelope, journal or effect
record shape changes. P09: none for this change — the listener supervisor is
app wiring with no page/schema change; the S1 resume-reliability edits already
present on this branch are declared separately by their own task.

## 1. Trigger and roles

- Trigger: on-device logs show a resumed/cold-booted Worker waiting in
  `host.start()` on `/v1/http` while the gateway upstream is `127.0.0.1`. The
  Worker's `bot-runtime` plugin derives `identity/register`, `identity/cancel`
  and `approval` URLs from `PDSH_PHONE_MCP_URL`; that URL is the App's own
  `BotMCPHTTPServer` (`NWListener` on `127.0.0.1:any`). iOS reaped the listener
  while the App was suspended, the old port stayed in the Worker environment,
  and the gateway's `waitsForConnectivity=true` URLSession cost 10–30 s per
  attempt (600 s resource timeout).
- Current: `BotMCPHTTPServer.stateUpdateHandler` handled only the first
  `.ready`/`.failed`; after `start()` returned, a later `.failed`/`.cancelled`
  was ignored. Nothing rebuilt the listener on foreground return, resume or
  cold start, and loopback gateway requests shared the external upstream
  session and its connectivity wait.
- Expected: the listener detects post-ready failure, can rebind the previous
  port (keeping URLs valid) or announce a new port, the App heals it before
  every foreground/resume/Host build, and a dead loopback upstream fails fast
  without waiting for connectivity.
- Roles: coordinator / contract owner, Swift implementer and reviewer are one
  agent for this task, producing each role's output.
- Owning contracts: P05 (`spec/v1/gateway-security.md`, `Sources/PhoneDSHGateway`),
  P26 (`spec/bot/v1/README.md`, `Sources/PhoneDSHBot/MCP`) and P27
  (`examples/probe-app/PhoneDSHProbe/Bot`). No owning spec file needed a change
  because this is a transport-liveness/timeout policy delta, not a new field,
  method, error code or envelope.

## 2. Delta

| Item | Before → After |
| --- | --- |
| Listener state | `.ready` only until `start()` returns → keep observing; post-ready `.failed`/`.cancelled` logs once and marks unhealthy |
| Listener recovery | none → `BotMCPHTTPServer.ensureListening()` probes the loopback endpoint, rebinds the previous port first, falls back to `.any` and calls `onEndpointChange` on a changed URL |
| App timings | foreground/resume/cold start never healed the listener → `BotMCPListenerSupervisor` calls `ensureListening()` on `.active`, immediately before `host.resume()`, and before every `makeHostLaunch()` (cold start and engine rebuild) |
| URL handoff | `PDSH_PHONE_MCP_URL` fixed at composition preparation → composition updates `workerEnvironment`; a changed port marks the built Host stale, so the App rebuilds instead of resuming the old Worker URL. A same-port rebind resumes normally |
| Loopback gateway | one URLSession, `waitsForConnectivity=true`, request timeout = configured (default 60 s), resource 600 s → separate local session: `waitsForConnectivity=false`, request/idle timeout `min(configured, 30 s)`, resource unchanged. External session unchanged |
| Redirect/credentials | unchanged; both sessions share the same delegate/callback path and allow-list |

No JSON-RPC method, HTTP path, header, status, capability, version, sequence,
error code, retry or durability rule changes. No new Worker variable: the
existing `PDSH_PHONE_MCP_URL` value is refreshed only before a new Worker boot.

Self-check (AGENTS §2): one authority (P05) still decides upstream admission;
no second envelope or error code; the local session only changes transport
timing for hosts already admitted by the same allow-list. No dependency or
native ABI change.

## 3. Compatibility

| Producer → Consumer | Support / rejection and tests |
| --- | --- |
| old Worker → new App | Same `PDSH_PHONE_MCP_URL`/token and routes; only the URL value can change on a new Host build. Worker code unchanged |
| new Worker → old App | Not applicable: the Worker environment is produced by the same App process. A downgraded App restores the old listener behaviour |
| same-port recovery | URL, token and MCP session id remain valid; a resumed Worker continues normally (`BotMCPListenerRecoveryTests.testCancelledListenerRebindsTheSamePort`) |
| new-port recovery | The App rebuilds the Host before starting a Worker, so no Worker observes the old port after the change (`BotMCPListenerSupervisorTests.testNewPortMarksTheCapturedWorkerURLStale`) |
| persisted data | No disk format, journal, WAL or response-log change |

Android (`android/net`): no `waitsForConnectivity` equivalent; the gateway uses
`HttpURLConnection` with a 5 s connect timeout and 30 s read timeout, so a
refused loopback connection already fails without a 600 s wait and no Android
change is made. The ATS/allow-list and route policy stay as they are.

## 4. Verification

- `swift test --disable-sandbox --filter 'BotMCPListenerRecoveryTests|GatewayLocalUpstreamFastFailTests'` → PASS (4 listener + 3 gateway).
- `swift test --disable-sandbox --filter 'PhoneDSHGatewayTests|PhoneDSHBotTests|PhoneDSHTests|PhoneDSHLogTests|PhoneDSHKillTests'` → PASS: 1100 tests, 2 skipped, 0 failures (directory-import tests excluded).
- Simulator, targeted suite (`PhoneDSHSimTests/BotMCPListenerSupervisorTests`, launched through
  `simctl spawn` because this harness denies the xcodebuild PTY) → PASS: 4/4.
- Simulator, full `PhoneDSHSimTests` → 256 tests, 3 skipped, 4 failures (2 test cases) — both
  `BluetoothDevicesPageTests`, files untouched by this change; `sim-kill` 20/20 and `sim-probe`
  G0 passed.
- iOS device build (`xcodebuild build -destination 'generic/platform=iOS'`) → PASS. The local
  Xcode 26.5 / swift-collections 1.7.5 pair requires `OTHER_SWIFT_FLAGS` with `-disable-sandbox`
  and the package's experimental features; that mismatch pre-exists this change.
- `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-p0-conformance` →
  `phone-spec` PASS, `phone-cross-tree` PASS, `phone-p0-conformance` FAIL on the same single
  pre-existing page divergence (`files 0/0 1/0`) as `origin/main`; the P0 divergence set is
  identical to `origin/main`.
- Not run here: a physical-device suspend/resume cycle. The on-device suspension inference is
  not re-run in this sandbox.

## 5. Remaining risks

- The proactive check is one TCP connect, not an HTTP request; a listener that
  accepts and then fails per request is out of scope.
- A URL change while a Worker is running is repaired by a full Host rebuild;
  an in-place Worker environment mutation would need a P16 protocol change and
  is not attempted.
- `LoopbackServer` is host-owned and its URL is also the page origin; rebinding
  it in place would invalidate the loaded page, so it is rebuilt only with a
  Host. The incident logs prove it was alive (the Worker reached the gateway).
  TonoLink relay/port-forward listeners already relisten on `.failed`/`.waiting`
  for an enabled USB session and are unrelated to Bot resume.
- Physical-device suspension/resume remains NOT_RUN in this environment.
