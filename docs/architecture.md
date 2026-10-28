# phone DSH: DeepSeek Harness in WKWebView

Status: this page describes the code that is in this repository. Every iOS and
WebKit statement is `NOT_VERIFIED` unless it is an Apple/WebKit documented fact
that is cited. Nothing in this page is a device measurement.

## Positioning

phone DSH runs [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(DSH) **unmodified** in a WKWebView `Web Worker` through DSH's official
`webworker-runtime`, inside an iOS app. The app process is the host: it owns the
persistent log, the single loopback origin, the ordered channel, the model
gateway and every side effect that survives the WebContent process.

The integration is **zero DSH source patch**. DSH is consumed from the pinned
checkout (`plugins/dsh-pin.json`: version `0.2.1-rc.2`, commit `7be5505`). No
DSH source tree is copied, vendored or modified; the packer copies the pinned
build into the image, and stages two of those built packages for the one
compatibility rewrite below. The repository contains the host (Swift), the wire
contract, the Worker entry, the phone profile and the image tooling.
`scripts/ci/no_dsh_patch.py` enforces that source boundary.

The image has one controlled pack-time exception. Cordis types
`Fiber.dispose` as `() => Promise<void>`, but its effect wrapper returns `void`
once the fiber was already disposed. The `agent/disposed` listeners in the
pinned `@deepseek-ai/dsh-tool-subagent` and
`@deepseek-ai/dsh-file-reference-local` packages call `.catch` on that return
value, so that listener threw `TypeError: ... reading 'catch'` after a
successful workflow. During packing, `dispose-compat.mjs` stages only
those two built packages and rewrites exactly one anchored call statement in
each to `Promise.resolve(fiber.dispose())...`. The original disposer still runs
synchronously on the same `this`; a rejection still reaches the existing
listener, and `file-reference-local` still tracks the normalized promise in
`promptDisposals` until it settles. A missing or duplicated anchor/statement
fails the pack instead of guessing, and `sizes.json` records the pinned
commit/version plus the source and transformed SHA-256 hashes. The checkout is
never written, and no Promise prototype, Cordis wrapper, context, agent loop or
VFS is changed. The staged copies also carry a `node_modules` view linking each
declared dependency and peer to the pinned workspace or install directory, so
the packer resolves the same closure from `tmpdir()` that it would from the
checkout. The regression tests load the real built packages and drive their
actual listeners with a real Cordis fiber (void, rejected and pending disposal);
the integration test runs `packVfsImage` over a `tmpdir()` stage and requires an
empty `missing` list plus both rewritten statements in the packed files. See
[Cordis disposal compatibility](../plugins/scripts/README.md#cordis-disposal-compatibility).
The durable fix is recorded as a [pending upstream proposal](upstream/README.md).

What this gives an app:

- the full official DSH plugin tree — model adapter, tools, sub-agents, session
  persistence — instead of a reimplementation;
- a durable, restartable workspace whose authority is the Worker's in-memory
  VFS and whose recovery log is the WAL in the app container;
- a phone-safe execution split: commands that can write stay in the Worker,
  only read-only accelerators cross into the app process;
- a facade-level handoff path (`PhoneDSHHost.beginHandoff()`, `reclaim()` and
  `reclaim(using:)`) for a remote DSH host, with a non-secret
  durable `handoff-intent.json`; the deployed remote peer and the end-to-end
  handoff over real transport are `NOT_RUN` (see
  [Known limits](#known-limits)).

What it does not give an app: a JIT in a plain app process, child processes, a
desktop shell, or device-verified numbers. Lockdown Mode disables the local
Worker and is reported as such; see [Budgets and failure modes](#budgets-and-failure-modes).

## Architecture

The architecture has four layers. The engine and host layers face each other
across one loopback origin; the ordered channel is the protocol between them.

| Layer | Runs in | Responsibility | Code |
|---|---|---|---|
| Engine layer | WKWebView web process | official DSH plugin tree; `webworker-runtime` (`node:*` compatibility, in-memory VFS authority, captured HTTP listener); our Worker entry (VFS sink, API bridge, console) | pinned DSH checkout + `plugins/worker-entry` |
| Host layer | app process (Swift) | one loopback HTTP/WebSocket origin; WAL and materialized copy; model gateway; host/step state machines; fence; budgets; WKWebView lifetime | `PhoneDSH*` modules |
| Execution layer | Worker and app process | Worker shell (`bash -c`, writes) and the WASI programs the boot installs from the image (`python3`, `jq-wasi`); read-only accelerators in the app process; remote offload | `plugins/shell-ext`, `plugins/wasi-toolbox`, `PhoneDSHShell`, handoff client |
| Long-running layer | app process, cross-cutting | two-tier promise, background drain, planned restart, lifecycle gate, handoff and reclaim | `PhoneDSHController`, `PhoneDSH/Background`, `PhoneDSH/Handoff` |

```
┌──────────────────────────── WKWebView (web process) ─────────────────────────┐
│  page (index.html + boot.js)                                                   │
│    └── Worker: DSH plugin tree + official webworker-runtime                    │
│          in-memory VFS (authority)   captured node:http listener              │
│          our Worker entry: VFS sink · API bridge · console · mux (D23)        │
└───────────────▲──────────────────────────────┬───────────────────────────────┘
                │ same-origin fetch            │ one ordered binary WebSocket
                │ page/static/image/lazy       │ VFS · EXEC · JOURNAL · API
                │ /v1/http (model egress)      │ LIFECYCLE · FENCE · CONSOLE
┌───────────────┴──────────────────────────────▼───────────────────────────────┐
│  app process (Swift): PhoneDSHHost                                           │
│    LoopbackServer ── WorkspaceLog (WAL, epochs, materialized copy, overlay)   │
│    ModelGateway (credentials, SSE, response log)   Controller (states, fence) │
│    WebEngine ── WKWebView lifetime   ExecProvider (read-only accelerators)    │
└──────────────────────────────────────────────────────────────────────────────┘
```

### The ordered channel

One binary WebSocket carries every host↔Worker side effect. The contract is
[spec/v1/channel.md](../spec/v1/channel.md); the Swift and
TypeScript codecs share the golden vectors in
[spec/v1/golden/](../spec/v1/golden/README.md).

- 16-byte big-endian header: `magic u16 = 0x5A4C`, `type u8`, `flags u8 = 0`,
  `seq u64`, `len u32` (`1…16 MiB`). The first frame of every connection and
  direction is `HELLO` with `seq = 1`.
- 18 frame types: `HELLO`, four VFS frames, three EXEC frames, two JOURNAL
  frames, four API frames, `LIFECYCLE`, `CONSOLE`, `FENCE`, `ERROR`.
- `seq` is a per-connection ordering check only. Application idempotency has a
  separate key per family (D2): VFS mutations use the host-allocated `mseq`,
  journal records `(session_id, jseq)`, exec requests `idem_key`, remote API
  requests `req_id` (the initiator re-issues after a reconnect).
- `mseq` is persistent, globally consecutive and never reused (D3/D17). The host
  sends `next_mseq`/`acked_mseq` in `HELLO`; the Worker numbers each `VFS_MUT`
  from `next_mseq`; on reconnect it re-sends every `mseq > acked_mseq` with the
  original number.
- `/v1/http` is the only model path; it is *not* carried on the channel. The
  channel carries exec, persistence, journal and the remote DSH API.
- `/dsh/tmp/**` is volatile and is never sent to the host. The sink only sends
  `/dsh/home/**` and `/dsh/workspace/**` (D4).

The ordered channel is served by the same loopback origin as the page, the
image shards, `/v1/http` and the app's MCP endpoint, so the Worker uses
same-origin `fetch` and a normal WebSocket. See
[spec/v1/README.md](../spec/v1/README.md) for terminology
and the protocol-version rules.

## Module map

These are the eight phone modules in `Package.swift`. All are MIT and none
depends on a GPL target.

| Module | Responsibility | Depends on |
|---|---|---|
| `PhoneDSHWire` | 16-byte frame codec (streaming), WAL record codec, CRC32C, canonical JSON payload types | — |
| `PhoneDSHLog` | WAL segments, epochs, group commit, two ack levels, materialized copy, overlay packing, cold recovery, quotas | Wire |
| `PhoneDSHLoopback` | the one loopback origin: page/static/image/lazy/overlay, channel upgrade, `/v1/http`, `/mcp*`, and the exec-bridge routes (`/v1/exec`, `/v1/fs/*`, `/v1/lifecycle`) when an exec bridge is configured | Wire, AgentCore |
| `PhoneDSHGateway` | model gateway: HTTP/2 upstream connections, SSE pass-through, bounded response log, retry/backoff, host-side credential injection | AgentCore |
| `PhoneDSHController` | nine host states, seven step states plus terminal `abandoned`, fence token, side-effect ledger, budget table, restart scheduler | Wire, Log |
| `PhoneDSHEngine` | WKWebView host: 1 pt visible attachment, page and Worker boot, process-termination reporting, planned restart, Lockdown Mode reporting | Loopback |
| `PhoneDSHShell` | `ExecProvider` wrapper for the read-only pdsh-shell accelerators over the WAL's materialized copy | AgentCore |
| `PhoneDSH` | facade `PhoneDSHHost`: assembles the services, exposes `AgentHarness`, diagnostics and the handoff/reclaim entry points, owns the ordered event stream, background helpers, handoff client/coordinator | all of the above + AgentCore |

`PhoneDSHAgentCore` (Foundation only) is the dependency boundary every phone
module builds on: it holds the credential, exec, agent-harness, DSH Remote and
exec-bridge host contracts, so an app that embeds phone DSH supplies its own
implementations of those protocols without depending on anything else.

`PhoneDSH` is the only product an app links; the others are its
implementation. The TypeScript half of the system lives in
[plugins/](../plugins/README.md): `channel`, `worker-entry`,
`shell-ext`, `wasi-toolbox`, the six DSH plugin packages, the profile and the
image tooling.

### Harness test support and the resolver gate

`PhoneDSHHarness` is a ninth, regular SwiftPM library target that exists
only to support the test harnesses. It is **test support, not app-facing API**:
it is not part of the `PhoneDSH` umbrella and no app product links
it. It holds the one copy of the scripted model upstream
(`MockModelUpstream`), the smoke evidence readers (WAL replay, journal and
step-machine readers in `SmokeSupport`), the kill-matrix support
(`KillSupport`, `KillWorker`, `verifyKillWorkspace`) and the shared `probe-site`
page/Worker fixture. It never imports XCTest. The macOS XCTest suites and the
iOS Simulator `PhoneDSHSimTests` target both link its `.library` product;
`examples/probe-app/project.yml` path-includes no file from
`Tests/`.

The reason for the regular target is a resolver gap: Xcode's package resolver
rejects a test target that depends on another test target, while the SwiftPM
command line accepts that graph. `swift test` can therefore stay green while
`xcodebuild build-for-testing` for the probe project stops before any suite
runs. The fast CI stage `scripts/ci/xcode-resolve.sh` (stage
`phone-xcode-resolve` in `scripts/ci/check.sh`) first rejects that edge
directly from the manifest-only target graph
(`scripts/ci/package_graph.py`), then regenerates the probe project
exactly as `sim.sh` does and runs
`xcodebuild -resolvePackageDependencies -scheme PhoneDSHSim` without booting a
simulator. The static check fails before any package checkout, so the defect
fails fast and deterministically; the Xcode resolution remains the
authoritative proof that Xcode accepts the graph. Any task that changes
`Package.swift`, `Tests/PhoneDSH*` or
`examples/probe-app/**` must include that stage in its gate; the full
`scripts/ci/sim.sh` run remains the end-to-end evidence.

The AppKit event pump is not duplicated in the harness: it is
`WebEngineAppKitEventPump` in `PhoneDSHEngine`, guarded by
`#if canImport(AppKit)`, next to the page-visibility precondition it serves
(see [Page visibility](#page-visibility)). The shared harness wait uses that
pump on macOS and a plain sleep on iOS, so iOS compiles the AppKit code out.

## Integrating `PhoneDSHHost`

### What the app supplies

| Input | Where | Notes |
|---|---|---|
| Workspace root | `PhoneDSHConfiguration.workspaceRoot` | `Library/xl/<workspace_id>/`; the directory must already exist |
| Packed Worker assets | `PhoneDSHBundleLocation` | a static directory with `index.html`, `boot.js`, `worker-entry.js`, `image.tar.gz` and `lazy/` |
| Per-start loopback token | `PhoneDSHConfiguration(token:origin:)` | random per launch; only the app and the loopback origin see it |
| Model credential provider | `configuration.credentialProvider` | a `CredentialProvider`; the Worker never receives a key |
| Exec provider (optional) | `configuration.execProvider` | read-only accelerator launcher; `nil` uses `configuration.accelerators` |
| Accelerator names | `configuration.acceleratorNames` | must equal the provider's channel caps (`channelAcceleratorNames`); empty advertises none |
| Budgets (optional) | `configuration.budgets` | defaults to the row for `deviceTier` (8 GiB row) |
| Engine factory (normally) | `PhoneDSHHost(configuration:engineFactory:)` | lets the app create the `WebEngine` on its UI actor and **attach the view** |

The app builds the bundle from the image tooling; the production artifact is not
committed. See the
[probe runbook](runbook-probe.md#build-the-artifacts) for the build
commands and for the exact asset names.

### Configuration

```swift
import Foundation
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHAgentCore          // CredentialProvider, StaticCredentialProvider
import PhoneDSHShell              // PDSHShellProvider

// Build these once, on the app's UI actor.
let accelerators = PDSHShellProvider(workspaceRoot: workspaceURL)

let configuration = PhoneDSHConfiguration(
    workspaceRoot: workspaceURL,                 // Library/xl/<workspace_id>/
    token: UUID().uuidString + UUID().uuidString, // per launch; never persisted
    origin: URL(string: "http://127.0.0.1")!,
    deviceTier: .eightGB,
    bundle: PhoneDSHBundleLocation(staticDirectory: bundleURL),
    allowedModelHosts: ["llm.example.com"],
    // The key never reaches the Worker: the host gateway injects it per request.
    // Read it from the Keychain; StaticCredentialProvider just holds it in memory.
    credentialProvider: StaticCredentialProvider([
        CredentialScope(service: "llm.example.com"): Credential(kind: .bearer, value: apiKeyFromKeychain)
    ]),
    execProvider: accelerators,
    acceleratorNames: accelerators.channelAcceleratorNames, // excludes bridge-only commands when no PhoneToolBridge is injected
    budgets: nil)                                 // use the tier row

let host = PhoneDSHHost(configuration: configuration, engineFactory: { engineConfiguration in
    await Task { @WebEngineUIActor in
        let engine = WebEngine(configuration: engineConfiguration)
        engine.attach(to: containerView)           // must be in a window; ≥ 1 pt visible
        return engine as any WebEngineControlling
    }.value
})
try await host.start()
let harness = try await host.harness()            // any AgentHarness
```

`origin` is a placeholder; the engine boots from the actually bound
`127.0.0.1` origin and port. The host also injects the Worker environment
(`PDSH_DSH_LAUNCH_TOKEN`, `PDSH_CHANNEL_URL`, `PDSH_CHANNEL_TOKEN`,
`PDSH_CHANNEL_ORIGIN`) from the bound listener; entries the app put in
`configuration.engine.environment` win for the same name.

`start()` is idempotent while starting or running. A host restored in `Backoff`
throws `PhoneDSHError.backoffNotElapsed(_:)` until its retry deadline. A failed
host stays failed until the user acknowledges it with `reset()`/`userReset()`.

The app drives the app-lifecycle edges:

| App event | Call |
|---|---|
| scene becomes active and the host was parked | `try await host.resume()` |
| scene goes to background | `try await host.park()` (drains, closes an epoch, stops the listener) |
| periodic maintenance (every 2 h of foreground work, at a tool-call boundary) | `try await host.plannedRestart(reason:)` |
| user acknowledges a fail-loud state | `try await host.userReset()` |
| app teardown | `try await host.stop()` |

The ordered event stream is `host.eventStream()`: state changes, controller
transitions, budgets, WebContent terminations/restarts, Worker hello, console
lines and fail-loud errors. `host.diagnostics()` is a snapshot for the
diagnostics screen; it contains no tokens or credentials.

### Credentials

The Worker never holds a model key. The model gateway asks the app's
`CredentialProvider` for `CredentialScope(service: <upstream host>, audience:
<normalized request path>, scheme: <lowercased URL scheme>, port: <explicit
URL port>)`: the service is the lowercased host of the request URL, the
audience is the path (`/` when the URL has none), and the optional scheme/port
distinguish origins that share a bare host. It applies the credential itself.
It strips every inbound `authorization`, `proxy-authorization` and `x-pdsh-*`
header, including the exec-bridge upstream-authorization relay, before
injecting the host credential. The selected model profile's endpoint scopes the
model key to that scheme/host/port and to the model-protocol paths derived from
its base (`/v1/messages`, `/v1/models`, model files, `/chat/completions`,
`/responses`, and the origin `/models` listing). Resource prefixes match whole
path segments, so `/v1/models-mcp` is not the model route; a same-host MCP or
arbitrary path receives `Credential.none`, not the model key. A redirect from a
credential-bearing request is followed only when its effective scheme, host,
port and normalized path are the same scope, and the gateway re-applies the
host credential URLSession omitted from the redirected request; otherwise it
returns the 3xx instead of forwarding the credential. `allowedModelHosts` is
the host allow-list: an empty set denies every upstream.
`PhoneDSHConfiguration` keeps the credential provider out of `Equatable` by
identity and out of diagnostics entirely.

The host/path pair is also the independent web-search boundary. The selected
`PhoneWebSearchSettings` mode wraps the model provider in a router: only the
normalized `/search` and `/fetch` operation paths on the configured search host
read the dedicated search Keychain account and return a bearer credential; a
same-host model request such as `/v1/messages` is delegated to the model
provider and keeps the model key. A missing search key, a missing audience on
the search host or an invalid/corrupt search document fails closed and never
falls back to the model key. The search route's exact scheme/host/port rule is
merged into the gateway allow-list, so the independent host is reachable without
being mistaken for the model host. Hosts that are neither the model host nor an
allowed egress host still receive no credential (the model provider refuses
them, or returns `Credential.none` for an anonymous egress host).

The Worker profile selects the official DSH web providers from the same
host-owned decision. Independent Search/Fetch mode exposes
`PDSH_WEB_SEARCH_PROVIDER=deepseek-search-api`,
`PDSH_WEB_FETCH_PROVIDER=deepseek-fetch-api`, the configured base and a
non-secret `DEEPSEEK_SEARCH_API_KEY` placeholder; the mounted
`web-deepseek-api` row registers both providers. Explicit follow-model mode
exposes `deepseek-official` only when the selected model service is the official
DeepSeek Messages endpoint the provider actually supports. With no selection,
neither `web-search-deepseek` nor `web-deepseek-api` is mounted, so an
arbitrary OpenAI-compatible model endpoint cannot silently claim web search. The
native page is reachable from both the full Web surface menu and the native
recovery settings page; saving or deleting only updates the document/Keychain
and the existing lifecycle-gated restart applies it.

The per-start loopback token is a credential too: it authenticates the page,
the channel upgrade and the privileged routes; keep it in memory, do not log it
and do not put it in persisted settings.

### Exec provider and the executor inversion

D12 inverts the usual split: a command that can write the workspace stays
inside the Worker; only a **read-only** accelerator advertised by the host HELLO
caps (`accelerator:<name>`) is sent to the app process as an `EXEC_REQ` frame.

- `bash -c`, shell builtins, the Worker's `git` program, installed WASI programs
  and every other command that can write run in the Worker's own shell
  (`plugins/shell-ext` over `just-bash`, reading and writing the in-memory
  VFS). Their writes are normal VFS mutations and reach the sink/WAL.
- The configured `ExecProvider` receives only the names the host HELLO
  advertised in `acceleratorNames`. The linked Rust production registry
  registers the six accelerator families (`rg`, `jaq`/`jq`, `ts-parse`,
  `ts-query`, `phone`, `ctx`); `phone` and `ctx` are registered and advertised
  only when a `PhoneToolBridge` exists. `PhoneDSHShell` reads the WAL's
  materialized copies (`materialized/workspace`, `materialized/home`) and has no
  write operation. A name the host did not advertise keeps running Worker-local
  (for example `just-bash`'s own `rg`, or the `jq` command when the Worker's
  WASI engine is staged).
- An exec request carries `requires_mseq` (the sink mutation the host must have
  applied before the command runs) and `idem_key` (the D10 key). The host holds
  the run until the WAL has acknowledged `requires_mseq`, and replays the
  recorded events for a repeated `idem_key` instead of running it twice.
- `exit` is sent as its own frame immediately; it never waits for a batch.
- The Apple link is still opt-in: `PDSH_WITH_XZSHELL=1` (or the historical
  `PDSH_WITH_SHELL=1`) plus a built `shell/dist/PDSHShell.xcframework`. Without
  it, `PDSHShellProvider` advertises no accelerator and fails every run with
  `PDSHShellError.notLinked` instead of claiming a capability it does not have.
  The Rust registry/FFI path has component tests. Build all three Apple
  XCFramework slices and run the linked Swift gates on the source being
  evaluated; those receipts do not establish physical-device behaviour.

### Command and capability boundary

The model does not get to discover the runtime by trial and error. Before the
first API request the Worker entry publishes two files into its persisted home:

- `/dsh/home/AGENTS.md` — a summary capped at **4 KiB**: the command surface,
  Python capability and gaps, file/output/request budgets, the egress
  allow-list, `/tmp` and `/dsh/tmp` semantics, the recorded non-GNU bash
  deviations and the restart rules. The unmodified upstream
  `agent-instructions` row injects it as `$DSH_HOME/AGENTS.md` (the phone
  `$DSH_HOME` is `/dsh/home`), which is why this needs no DSH patch. The
  profile keeps that row enabled and `scripts/pack-image.mjs` fails the image
  build if the roster or profile drops/disables it.
- `/dsh/home/capabilities.json` — the full machine-readable answer
  (`schema: pdsh-capabilities/1`): `commands[]`, `python_modules[]`, `limits{}`,
  `network.egress_allow[]`, `bash.deviations[]` and `host_caps[]`. The shell's
  127 trailer from the class contract (ENG-02) already names this path, so a
  model that asks for a missing program is pointed at the same truth.

The facts are enumerated, not hand-written. `commands[]` comes from the live
shell table — just-bash's registry, `createWorkerCommands()`, the installed
WASI toolbox and the host HELLO accelerators — and a test asserts an empty
two-way difference against the real table. `python_modules[]` is a build-time
probe of the produced `python313.zip` staged beside the CPython pair by
`scripts/pack-image.mjs`; `egress_allow[]` is the init message's
`xl.egressAllow` array (or its `PDSH_EGRESS_ALLOW` environment entry; the host
enforces the same list on `/v1/http` and the Worker never opens a socket).
`buildCapabilityManifest()` is a pure function; `publishCapabilityManifest()`
compares a SHA-256 content hash and writes only when the content changed, so a
Worker restart over unchanged persisted home emits no `VFS_MUT`.

The WASI toolbox is installed by the Worker entry by default, not left for the
host to wire. At boot the entry binds the python lifecycle and the jq lifecycle
against the live VFS:

- `python3` comes from `/dsh/bin/python/python.wasm` plus
  `python313.zip`, and is published on the shell table before the first API
  request. The standard probe/smoke image build obtains those artifacts through
  `scripts/ci/python-artifacts.sh`; a deliberately Python-free bundle must opt
  out with `--without-python`, and an image without the artifacts logs one
  visible "python3 stays unavailable" line instead of pretending the command
  exists.
- `jq` binds the real WASI engine from `/dsh/bin/jq/jq.wasm` plus
  `engine.json`. The entry verifies the report's engine identity, byte count and
  SHA-256 before advertising it, registers it as `jq-wasi` (alias `jaq`) on the
  same toolbox, and the shell `jq` command routes to it when present. An
  explicitly advertised host `jq` accelerator is the separate read-only path
  and takes precedence for that name. The module is loaded on demand by the
  WASI toolbox. An image without the artifact keeps the fail-loud shell shim
  and the capability manifest does not advertise the engine.

Staging is a build-product step: `--python`/`PDSH_PYTHON_WASM` and
`--jq`/`PDSH_JQ_ARTIFACTS` supply the bytes, and `scripts/ci/smoke.sh` supplies
both for its standard image. That is implementation and wiring evidence, not a
claim that every Python module, every jq filter or every GNU/desktop behaviour
exists. The phone is not a complete desktop POSIX host: the shell is
`just-bash` with recorded deviations (not GNU bash/POSIX), `python3` is CPython
on WASI with the staged stdlib and no host process, and `jq` is a real
jaq-core engine with documented semantic deviations, not full jq 1.6/GNU
compatibility. `AGENTS.md` and `capabilities.json` are the model-facing copy of
those limits.

Two related boundaries are visible in the same files (ENG-01/ENG-02/ENG-08):
every path goes through one namespace (`/tmp` and `/dsh/tmp` are one volatile
store; `/dsh/home` and `/dsh/workspace` are the only persisted roots, `/tmp` is
never sent to the sink), every failure from this layer ends in one
`pdsh-shell: exit=… program=… reason=… hint=…` line, and the single-file budget
is the host's clamped value (64 MiB at the 8 GiB tier, up to 128 MiB when the
tier allows) with the same number reported to the model.

Acceptance is covered by `plugins/worker-entry/src/capability-manifest.test.ts`
(command-table two-way diff, allow-list and Python list equality, 4 KiB cap,
the real upstream loader picking the file up, and the second-boot no-`VFS_MUT`
check) and by `plugins/scripts/pack-image.test.mjs` (module probe and the
profile/roster assertion). The jq wiring has its own Node suite
(`tests/jq-wasi-engine.test.ts`) and the Python runtime has
`worker-entry/src/python-subprocess.test.ts`; those are unit/component evidence,
not a real-model run. The real-model rerun of G2-A05/G2-A06 is the external
check: its probe-request count must drop below the recorded baseline, and that
rerun must have a source-bound real-model receipt before it is accepted.

### UI attachment requirement

The WKWebView must be attached to a window and have at least **one point** of
visible area (`WebEngineConfiguration.requiredVisibleAreaPoints = 1`).
`WebEngine.attach(to:)` sizes the view to that minimum and sets its alpha to
0.01, so the app can draw a placeholder over it. This is a WebKit precondition,
not an optimisation: a detached or fully clipped WKWebView may be throttled or
suspended. The host refuses to boot when the engine reports
`isAttachedWithVisibleArea == false` (`PhoneDSHError.engineNotAttached`), and
refuses to run the local Worker in Lockdown Mode
(`PhoneDSHError.lockdownMode`).

The attachment check is geometric. WebKit also throttles an attached page
whose hosting window is not visible to the user, so the full production
precondition is `WebEngine/isVisibleForWebKit` (attachment **and** window
occlusion) plus a `visible` document; see
[Page visibility](#page-visibility). `WebEngine` warns at boot when the window
is occlusion-hidden.

Whether a one-point view stays unthrottled on a real iPhone is `NOT_VERIFIED`;
the probe package measures timer throttling on macOS.

### Page visibility

WebKit throttles a page it considers hidden: DOM timers fire late or not at
all, `fetch` body reads pause, and the Worker is scheduled like a background
page even though the WebContent process is alive and the view has a visible
area. The symptom in this stack is a Worker that stops after a progress step
while the host has already received the complete model response — a delivery
stall, not a model or tool failure.

The engine exposes both halves of the precondition (`NSWindow.occlusionState`
is an Apple-documented AppKit property:
<https://developer.apple.com/documentation/appkit/nswindow/occlusionstate>):

| Signal | API | Meaning |
|---|---|---|
| Geometric attachment | `WebEngine.isAttachedWithVisibleArea` | The view is in a window and at least 1 pt is not clipped (the facade refuses a boot otherwise). |
| Window occlusion | `WebEngine.isWindowOcclusionVisible` | macOS: `NSWindow.occlusionState` contains `.visible`. iOS: the app is active. `nil` when the view has no window. |
| Page state | `WebEngine/waitForVisiblePage(timeout:)` | Samples the two signals above plus `document.visibilityState`, and returns `isVisible` only when all three agree. |

`WebEngine/isVisibleForWebKit` is the window-level requirement: attached with a
visible area and occlusion-visible. An app that runs the platform main event
loop (`NSApplication.run`, `UIApplicationMain`) satisfies it automatically; no
app-side pump is needed. The requirement is `NOT_VERIFIED` on an iPhone: the
iOS branch reads `UIApplication.applicationState` and has not been run on a
device.

The XCTest harnesses are different. `swift test` starts a plain process that
never calls `NSApplication.run`, so ordering the window in and calling
`NSApplication.activate(ignoringOtherApps:)` only queues AppKit events. Until
the process dequeues and dispatches them, the window never becomes
occlusion-visible and WebKit keeps the page hidden. The smoke test, the
scenario runner, the Phase 0 probes and the kill matrix therefore wait through
one shared pump, `WebEngineAppKitEventPump` (the probe target mirrors it locally
because it does not link the engine module): while a run waits — boot, turns,
perturbations, assertions — the pump dequeues
`NSApplication.nextEvent(matching: .any, until:, inMode: .default, dequeue: true)`
and sends the event. A run-loop-only or `Task.sleep`-only wait leaves the page
hidden; that is the `swift test` failure this section documents.

The guardrails around the pump:

- Before the first smoke/scenario turn, `harnessAssertPageVisible` waits for
  the occlusion-visible window and the `visible` document and fails loud with
  the sampled state (and how to fix it) instead of hanging. The probe host
  performs the same check after a visible page loads.
- `WebEngine.bootWorker`/`restart` warn on the page console when the window is
  occlusion-hidden, so direct engine callers see the condition too.
- The scenario runner keeps its 12 s delivery-stall watchdog: when a turn has
  produced no harness event for 12 s it samples the same visibility signals;
  a page that is hidden or unresponsive fails the run with an actionable
  environment error. This is the runtime safety net (a locked screen or an
  occluded window), not a substitute for the pre-turn assertion.

Do not "fix" a hidden page by increasing budgets or disabling assertions: a
throttled page has no delivery deadline to wait out. Pump AppKit events in the
test harness, or keep the app foreground with its main run loop in production.

### Budgets and failure modes

`BudgetTable` contains policy constants, not measurements. The normative tier
rows — engine heap, VFS logical bytes with its workspace/sessions/tmp split,
single file, WASI hot instance, app process, peak, sub-agents, the loopback
target, the planned-restart interval and the `a + k·MB` recovery bound — are in
`spec/v1/budgets.md` §4, which also fixes how a tier is selected (once per boot
from the physical memory ceiling; the 8 GiB row is the default, a lower row
applies only when the ceiling is below it). The numbers are deliberately not
repeated here: the W12-BIGFILE revision reached the spec, the enforced VFS and
single-file quotas and the published manifest while a copied row on this page
(and the WASI hot-instance constant in `plugins/wasi-toolbox/src/limits.ts`)
kept the superseded values, and copying is what allowed the drift.

Persistent stores keep their own absolute quotas — the WAL, journal and
response log rows of `spec/v1/budgets.md` §5. An overflow compacts what is
droppable and then fails loud; `home/`, `workspace/` and un-journaled steps are
never evicted.
Under memory pressure the monitor emits at most one action per evaluation, in
the fixed order `clearTmp` → `plannedRestart` → `handoff`; a hard cap still
exceeded after those actions is `Failed` and needs the user.

The fail-loud path is deliberate: `Failed` is never left automatically, a boot
that finds a persisted `Failed` starts in `Failed`, and `reset()`/`userReset()`
is the only exit once the user has acknowledged the error.

## Persistence model

The Worker's in-memory VFS is the single authority while it runs. The app
container under `Library/xl/<workspace_id>/` is its recovery log and the
materialized copy; it is never synchronised back into the VFS. The full
byte-level contract is [spec/v1/wal.md](../spec/v1/wal.md);
this section is the one-page summary.

| Path | Contents |
|---|---|
| `wal/<epoch:08d>.<segment:06d>.xlwal` | WAL segments (40-byte header, `mseq`-keyed records, `op 0xFF` epoch-close records) |
| `materialized/home/`, `materialized/workspace/` | the last durable tree, derived from the WAL |
| `manifest.json` | `format`, `boot_id`, `materialized_upto_mseq`, `last_durable_epoch`, segment list, `last_mseq` |
| `steps/<session_id>/<step_key>.json` | the seven progress-step records plus the terminal `abandoned` owner record, written only by the host |
| `exec/` | the persisted exec idempotency ledger |

Write path for one VFS mutation:

1. the Worker applies the mutation in memory and emits a `VFS_MUT` with the next
   `mseq`;
2. the host validates the path, range, `mseq`, length and mode (a structural
   failure is a protocol error and closes the connection);
3. the host appends to the WAL (group commit, at most 2 ms) and sends
   `VFS_ACK` **level 1** — the bytes are in the kernel page cache, so they
   survive a process kill;
4. the host applies the record to the materialized copy in `mseq` order;
5. at an epoch boundary (every 30–60 s, background, before handoff, before a
   planned restart) it fsyncs the touched materialized files and directories,
   then `F_FULLFSYNC`s every segment written in the epoch, then atomically
   writes `manifest.json`; only then does it send **level 2**;
6. `materialized_upto_mseq` is a strictly consecutive watermark. An append that
   does not match its base asks the Worker for a full re-send
   (`VFS_RESYNC`); the watermark stops before the mismatching mutation.

The two acknowledgement levels are the **two-tier durability promise**: level 1
means “a process kill loses nothing”; level 2 means “this epoch is on stable
storage”. A power loss may lose at most the last epoch, at which point the
Worker memory is gone too and the tool journal shows which steps are missing.

Boot packs the materialized copy plus the WAL tail into a gzip-compressed
overlay (`home/` and `workspace/` only) served with `Cache-Control: no-store`,
so every WebContent restart mounts a fresh tree. Cold recovery scans `wal/`
rather than trusting `manifest.segments`; a torn tail record is truncated, a
non-tail CRC failure is `WAL_CORRUPT` and fails loud, and a missing manifest is
rebuilt only when the oldest segment starts at `mseq` 1 (D11/D19). A divergent
materialized copy is rebuilt only from a full `mseq` 1 history. For a compacted
history, recovery may instead restore just `home/AGENTS.md` and
`home/capabilities.json` from their retained complete full-write base plus a
hole-free suffix, after recording the preimage under the workspace-private
`recovery-backup/`; every other path, missing base or gap stays `WAL_CORRUPT`.

## Long-running tasks, handoff and the two-tier promise

The host state machine has nine states: `Running`, `Draining`, `Parked`,
`Recovering`, `Backoff`, `HandingOff`, `Remote`, `Reclaiming`, `Failed` (D14).
Admission is open only in `Running`; every authority change closes it first.

- **Park / resume (background).** `park()` follows `Running → Draining →
  Parked` with a 20 s drain window, closes a WAL epoch and stops the Worker and
  listener; the workspace services survive so `resume()` can boot quickly.
  A `Draining` deadline aborts in-flight channel requests; the initiator
  re-issues them on the next connection (D2).
- **Planned restart.** `plannedRestart(reason:)` closes admission, drains the
  in-flight `0x40` exchanges for at most 20 s, closes the epoch, rebuilds the
  overlay and the Worker, and waits for `HELLO`. The replacement Worker then
  gets the same bounded DSH write-open reconcile as an abnormal termination,
  so a tool call interrupted by a page/Worker kill cannot stay at
  `tool_dispatched`; only after that does the host verify the lease and reopen
  admission. The controller schedules the restart at a tool-call boundary
  every 2 h of foreground work (or after 60 s if no boundary arrives).
- **Background helpers.** `BackgroundDrainer` runs the 20 s window and the OS
  expiration callback; `BackgroundPolicies` maps thermal/battery signals to the
  sub-agent cap, pause and handoff suggestion; `PluggedInKeepAwake` disables the
  idle timer only while charging and `Running` and documents that it cannot
  prevent a manual lock; `TaskScreen` is the dimmed, static screen for long
  local work; `ContinuedProcessingDrainWindow` (iOS 26) attaches a
  `BGContinuedProcessingTask` to the ordinary drain only — no tool work runs in
  the launch handler. Their device scheduling is `NOT_VERIFIED`.
- **Handoff (D15).** With admission closed and an epoch flushed, the phone
  calls `POST /v1/handoff/fence` (generation CAS, returns a 128-bit
  `reclaim_token`), then `/v1/handoff/snapshot` (full tar of the materialized
  copy at `materialized_upto_mseq`), then `/v1/handoff/segments` (the WAL tail
  covering `(base, wal_seq]`); the remote opens admission only when its applied
  `mseq` equals `fence.wal_seq`. Reclaim is `POST /v1/handoff/reclaim` with the
  token only; it is idempotent for 24 h and returns the new segments and a
  fence `{owner: phone, generation + 1, wal_seq}`. The wire contract, HTTP
  client, tar reader, applier, simulator and coordinator are landed under
  `Sources/PhoneDSH/Handoff/` and tested against an in-process remote.

  The facade exposes the path: `PhoneDSHConfiguration.handoff` configures the
  remote endpoint and credential service, `beginHandoff()` closes admission and
  stops the local Worker before the snapshot, `reclaim()` returns the remote
  workspace, and `reclaim(using:)` accepts a typed token bound to the remote endpoint,
  generation and WAL fence for explicit cold-process reclaim. The deprecated
  raw-string token entry rejects unbound authority. Before the CAS the coordinator persists a **non-secret**
  `handoff-intent.json` (expected generation, WAL seq and endpoint); it never
  stores the token. The token lives only in the App-injected
  `HandoffReclaimTokenStore` (`InMemoryHandoffReclaimTokenStore` is
  process-lifetime only; `KeychainHandoffReclaimTokenStore` is the reference
  secure-vault implementation). A new host can reclaim with a stored token and
  a persisted remote fence, or with the pre-CAS intent plus a token-bound remote
  fence. If the CAS response is lost and **no token is available**, the host
  stays fail-closed and `reclaim()` throws
  `HandoffError.manualReclaimRequired`; this is a **BLOCKED manual-recovery**
  path, not an automatic reset. A definite pre-CAS rejection is the only case
  that is marked safe to clear and boot locally.

  The facade/coordinator/cold-safety tests are in `PhoneDSHFacadeHandoffTests`
  and `PhoneDSHHandoffColdSafetyTests`, against the in-process
  `HandoffServerSimulator`; they are implementation/unit evidence, not a
  deployed remote. A real remote DSH peer, TLS/ATS, real Keychain access, device
  suspension and the end-to-end handoff over transport are `NOT_RUN`.
- **The two-tier promise.** Foreground or charging, the device runs the task
  locally and continuously, subject to the budget table. Background or locked,
  it does not promise CPU time: it promises a checkpoint. The task resumes from
  the durable log after a restart, or is handed to the remote while the phone is
  away. This is the product promise; the iOS scheduling behind it is
  `NOT_VERIFIED` on a device.

## Running scenarios on the simulator and on a device

The G2 catalog runner is not tied to `swift test` on macOS any more. The
engine — catalog decoding, workspace seeding, perturbations, assertions,
report/transcript writers, the mock upstream adapter and the budget guard —
lives in the regular library `PhoneDSHScenario`
(`Sources/PhoneDSHScenario`, no XCTest import). Two thin XCTest
suites call it:

| Runner | Suite | Evidence |
|---|---|---|
| macOS (default) | `PhoneDSHScenarioTests`, run by `swift test --filter PhoneDSHScenario` | `<results>/<id>/{report.json,transcript.jsonl,workspace.tar,host/}` |
| iOS Simulator / device | `PhoneDSHScenarioSimTests` in `examples/probe-app`, run by `scripts/ci/scenarios.sh --run-on sim` | the same tree, pulled from `Documents/pdsh-scenarios/results/` |

Both write the same report schema, so `g2_run.py` and `g2_judge.sh` do not
change. `--run-on macos` keeps the `swift test` behaviour and environment.

```sh
# Simulator, no key:
bash scripts/ci/scenarios.sh --run-on sim --upstream mock \
  --only G2-SELFTEST,G2-SELFTEST-DELIVERY

# Simulator, real model (credentials only via the test-runner environment):
eval "$(node scripts/ci/model-env.mjs)"
bash scripts/ci/scenarios.sh --run-on sim --upstream real

# Tomorrow, on a signed iPhone (NOT_VERIFIED in this tree):
bash scripts/ci/scenarios.sh --run-on sim --upstream real \
  --destination 'platform=iOS,id=<device-udid>'
```

Staging layout in the probe app container: `Documents/pdsh-scenarios` holds
`catalog.json`, `fixtures/`, `config.json` (upstream/only/tag/target/keep_bodies,
never a key) and `results/`. The model key is passed as
`TEST_RUNNER_PDSH_MODEL_BASE_URL/NAME/API_KEY` to `xcodebuild` and redacted from
every artifact; it never appears in a staged file or a log. The host driver
reuses `sim.sh`'s boot/build/install/pull flow through
`examples/probe-app/scripts/sim-common.sh`.

`workspace_command` and `worker_command` are different acceptance locations
and the report keeps them separate (`host_evaluated` versus
`worker_evaluated`). `workspace_command` is **host acceptance**: the macOS
runner, or the simulator host phase after `xcodebuild test`, runs
`/bin/bash` against a throwaway copy of the materialized workspace. It proves
what that host shell sees; it does not prove the Worker's in-memory VFS.
`worker_command` runs while the live Worker is still reachable, over the
authenticated ordered channel, on an **immutable fork** of the Worker VFS. It
passes only on a typed `pdsh-worker-command/1` receipt whose
`location.kind = worker`, `location.worker_vfs = true`,
`location.host_process = false`, `location.fork = memory-vfs`,
`carrier = ordered-channel`, `source.kind = worker-vfs-fork`,
`source.fork = true`, `source.source_frozen = true` with one frozen
`source_mseq_start == source_mseq_end` watermark, the exact
scenario/session/turn/assertion binding, `model_requests = 0`,
`live_workspace_unchanged = true` and `side_effects.isolated = true`. A missing
or mismatched receipt is a failure; there is no host fallback and a
`surface-process` (desktop simulation) receipt cannot stand in for a Worker
one. The live route is implemented in `surface-phone` and validated by the
Swift typed receipt (`PhoneDSHWorkerCommandReceipt`) plus the scenario
evaluator. Node route tests are component evidence; acceptance additionally
requires a same-source real WKWebView receipt from the built Worker bundle.

`workspace_command` is the one assertion that needs a host process, so
`--run-on sim` evaluates it in two phases. Inside the simulator the assertion
is recorded as `status: "pending_host"` with its command text and the report
status is the provisional `PENDING_HOST` (never a pass); a settled failure or a
terminal `TIMEOUT`/`BUDGET`/`ERROR` keeps its own status. The simulator test
bundle spawns no process. After `xcodebuild test`, the host driver pulls the
results and runs the same shared implementation the macOS runner calls
(`ScenarioWorkspaceCommand.evaluateOrDefer`) against the pulled
`<results>/<id>/host/materialized/workspace/`, using the same `/dsh/workspace`
rewriting, `PATH`, 180 s watchdog and exit-0 verdict; `workspace.tar` is the
same tree archived before assertion evaluation but is not extracted. The host
phase rewrites `report.json` with the assertion's `ok`/`detail`, adds
`host_evaluated: true` and the command `duration_ms` (and a top-level
`host_evaluated: true`), and sets the final status by the macOS rule. The
driver's summary and exit code follow that final status; an un-finalized
`PENDING_HOST` report fails the gate. `G2-SELFTEST` carries such an assertion,
so `scenarios.sh --run-on sim --upstream mock --only G2-SELFTEST,G2-SELFTEST-DELIVERY`
exercises both phases. The report schema only grew optional fields, so
`g2_run.py` and `g2_judge.sh` need no change.

Perturbations on the simulator: `planned_restart`, `park_resume` and
`worker_kill` use the same facade and engine paths as macOS. `webcontent_kill`
cannot be signalled from the simulator test process; the scenario report says
`not available on this runner` with `ok: null` for that point rather than
silently skipping it. A hidden macOS page therefore no longer stops the
real-model line: the simulator keeps its WKWebView visible while the Mac
console is locked, and `--destination` carries the same catalog to a device.
The device branch is `NOT_VERIFIED`: signing, installation and the device
report are operator steps documented in
[the probe runbook](runbook-probe.md#running-the-same-catalog-on-a-real-iphone).

## Status

Each row states the highest level actually demonstrated for the named code
path. A lower level is never promoted to a higher one:

- **implemented** — the source/API exists in this tree, but no same-source gate
  result for it is recorded here.
- **unit-tested** — a named same-source unit/component suite passes; this says
  nothing about WKWebView, an iOS Simulator or a physical iPhone.
- **historical macOS gate** — the named gate ran on macOS on an earlier source
  revision. It is not a PASS for the current source.
- **historical simulator gate** — the named gate ran on the iPhone 17 Pro
  simulator on an earlier source revision and the reports said
  `environment: "ios-simulator"`. This says nothing about an iPhone.
- **NOT_RUN** — the named end-to-end gate has not run on the current source.
- **NOT_VERIFIED on device** — there is no physical-iPhone evidence.

A row becomes a current-source PASS only when a receipt records the source
commit, built artifacts, exact command and result. The pull request's validation
results carry those source-bound receipts, including the full 56-scenario
real-model G2 batch. This table describes gates and historical evidence rather
than embedding a moving final-run result in the code being tested. A macOS row
says nothing about iOS or a physical device; an in-process remote simulator says
nothing about a deployed remote peer.

| Capability | Status | Gate / evidence |
|---|---|---|
| Ordered-channel codecs and golden vectors (Swift + TypeScript) | historical macOS gate | `spec/v1/tools/spec_golden.py --full`; `PhoneDSHWireTests`; `plugins/channel/src/golden-frames.test.ts` |
| Single loopback origin: page, static, image/lazy/overlay, channel upgrade, `/v1/http`, MCP | historical macOS gate | `PhoneDSHLoopbackTests`; probe rows `channel.coop-coep-headers-*`, `channel.fetch-post-1kb`, `channel.fetch-post-1mb`, `channel.ws-echo-1000` |
| WAL append, group commit, epoch close, materialized copy, cold recovery | historical macOS gate | `PhoneDSHLogTests`; probe row `log.checkpoint-100-files`; the 20-iteration kill matrix |
| Host and step state machines, fence, side-effect ledger, budgets | historical macOS gate | `PhoneDSHControllerTests`, `PhoneDSHTests` |
| Model gateway `/v1/http`: SSE pass-through, retry, response log, host credential injection | historical macOS gate | `PhoneDSHGatewayTests`; the smoke's `api_key_injected` and second model request checks |
| WKWebView Worker boot and one real `bash` tool call | historical macOS gate | `scripts/ci/smoke.sh` → `PhoneDSHSmokeTests`; phases `boot_and_hello`, `first_tool_turn` |
| Planned restart, WAL and session resume | historical macOS gate | the same smoke; phases `planned_restart`, `resumed_turn` |
| Worker shell executor inversion (`bash -c` and workspace writes stay in the Worker) | historical macOS gate | the smoke's `bash -c` call (`echo hi > a.txt && cat a.txt`); `plugins/shell-ext` Node suites |
| Boot capability manifest (`AGENTS.md` ≤ 4 KiB + `capabilities.json`) read by the unmodified instruction loader; command-table truth and no-`VFS_MUT` second boot | unit-tested (Node capability suite) | `plugins/worker-entry/src/capability-manifest.test.ts` (8 tests passed in this task, including the upstream loader); `scripts/pack-image.test.mjs` covers the module probe and profile assertion but was not run here |
| Read-only native accelerators through linked pdsh-shell (`rg`, `jaq`/`jq`, `ts-parse`, `ts-query`, `phone`/`ctx` with a bridge) | implemented; linked acceptance required | Rust registry/C-ABI tests, `bash shell/build-apple.sh` (iOS, iOS Simulator, macOS), then `PDSH_WITH_XZSHELL=1` linked provider, bridge-safety and Host suites. Physical-device acceleration remains NOT_VERIFIED |
| Probe package: Worker channel, timer throttling, JIT benchmark, 100-file checkpoint | historical macOS gate | `scripts/ci/probes.sh` → `PhoneDSHProbeTests` (5 tests, G0 gating clean in that run) |
| Kill matrix: 20 seeded kills, WAL/materialized/step consistency after recovery | historical macOS gate | `scripts/ci/probes.sh` → `PhoneDSHKillTests` (20/20 iterations in that run) |
| Handoff/reclaim facade, cold-process reclaim and non-secret CAS intent | implemented; in-process acceptance required | `beginHandoff()`, `reclaim()`, typed `reclaim(using:)`; `PhoneDSHFacadeHandoffTests`, `PhoneDSHHandoffColdSafetyTests`, `Handoff*Tests`. Real peer/transport remains NOT_RUN; tokenless uncertain CAS requires manual recovery |
| Worker command acceptance (`worker_command`) distinct from host `workspace_command` | implemented; actual Worker acceptance required | Controller and typed Swift receipt suites, then fresh WKWebView Bash/Python fork positives and timeout negative. Receipts must bind the immutable source fork and prove live-state preservation; host-copy `/bin/bash` is only host evidence |
| Default `python3` install from image artifacts | unit-tested (Node) | `worker-entry/src/python-toolbox.ts` binds the lifecycle at boot; `worker-entry/src/python-subprocess.test.ts` passed (real published `python3` serves subprocess on the shared VFS); absent artifacts keep `python3` unavailable instead of faking it |
| jq WASI engine lazily wired from `/dsh/bin/jq` | implemented; fresh WASM acceptance required | Build from the tracked locked Rust source, verify `engine.json`/SHA-256, and run `tests/jq-wasi-engine.test.ts` without artifact skips. Absent artifacts keep the fail-loud shim; compatibility deviations are documented |
| Background drain window and thermal/battery decisions | historical macOS gate | `BackgroundDrainerTests`, `BackgroundPolicyTests`, `BackgroundKeepAwakeAndTaskScreenTests` |
| Simulator G1 rehearsal: Worker boot, one real tool call, WAL/materialized/journal/step-machine assertions, planned restart with the gzip overlay, single `.restarted` event, resumed session | historical simulator gate | `scripts/ci/sim.sh` → `PhoneDSHSimTests` smoke suite (`smoke-report.json`: every gating row PASS in that run) |
| Simulator channel probes: loopback round trip p95, COOP/COEP on and off, fetch POST 1 KB/1 MB, NDJSON first chunk, WebSocket echo, 100-file checkpoint | historical simulator gate | the same gate, `probe-report.json` via `ProbeKit` (throttle and JIT rows are informational) |
| Simulator kill matrix: Worker terminate and WebContent restart across the four timings, acked state preserved | historical simulator gate | the same gate, `kill-report.json` (5 iterations; the real WebContent kill is informational and scoped to the selected simulator by `SIMULATOR_UDID`) |
| Full 56-scenario real-model G2 batch | source-bound receipt required | Run the unchanged catalog/prompts/budgets against the frozen tree and its built assets. Finalize every host phase; report FAIL/BUDGET/ERROR/missing cases explicitly. Older reports do not become a new-source PASS |
| Physical iPhone end-to-end (signing, install, real WKWebView, real provider) | NOT_RUN | no device evidence; simulator evidence says nothing about an iPhone, and the operator steps are in the probe runbook |
| Background scheduling, idle timer, Lockdown Mode, jetsam, on-device JIT/memory | NOT_VERIFIED on device | no device run; budget values are constants, not measurements |

How the table is filled: a gate name alone is not a PASS. The same-source
report must record the source commit, the exact command and its result; until
then the row is `implemented`, `unit-tested`, historical or `NOT_RUN`. The
commands in the [probe runbook](runbook-probe.md) reproduce the
historical macOS/simulator runs. Rebuild a changed `plugins` tree with the same
scripts before relying on an old smoke image. Node-only suites are component
evidence, not WKWebView or iPhone evidence.

## Known limits

- **Handoff is wired, but the deployed peer is not verified.** The facade
  exposes `beginHandoff()`, `reclaim()` and `reclaim(using:)`, and a
  new host can reclaim from a durable non-secret intent plus a token in the
  App's secure store. The repo's tests use the in-process
  `HandoffServerSimulator`; a real remote DSH deployment, TLS/ATS, real
  Keychain access and device suspension are `NOT_RUN`. If the fence CAS
  response is lost and no token is available, the host stays fail-closed and
  raises `HandoffError.manualReclaimRequired`; automatic recovery is not
  invented, so that case is **BLOCKED** pending manual recovery with the saved
  token or an operator decision.
- **No physical-iPhone evidence.** The simulator gate (`scripts/ci/sim.sh` with
  the `examples/probe-app` targets) proves iPhone 17 Pro simulator
  behaviour only; the probe app builds for the simulator and has not run on an
  iPhone, so throttling, JIT, memory/jetsam, Lockdown Mode and background
  scheduling stay `NOT_VERIFIED on device`.
- **Lockdown Mode disables local DSH.** The engine reports the system flag and
  `harness()` throws `PhoneDSHError.lockdownMode`; there is no in-app JIT
  workaround.
- **The native accelerator XCFramework is opt-in and must be built.**
  The tracked Rust registry now registers the six accelerator families
  (`rg`, `jaq`/`jq`, `ts-parse`, `ts-query`, and `phone`/`ctx` only with a
  `PhoneToolBridge`). `PDSH_WITH_XZSHELL=1` plus
  `shell/dist/PDSHShell.xcframework` is still required; without it the provider
  compiles its honest stub, advertises nothing and fails loudly. Three-slice
  build and linked Swift results require source-bound receipts;
  neither establishes on-device native acceleration.
- **WASI programs are installed by default only when the image carries their
  artifacts.** The Worker entry binds `python3` from
  `/dsh/bin/python/{python.wasm,python313.zip}` and the real jq WASI engine from
  `/dsh/bin/jq/{jq.wasm,engine.json}`; the standard smoke/probe image build
  supplies both, and `--without-python`/`--without-jq` deliberately omit them.
  An image without an artifact keeps `python3` unavailable (one loud log line)
  or keeps the fail-loud `jq` shim, never a fake command. Python is CPython on
  WASI with the staged stdlib, not a host process; jq is jaq-core with
  documented deviations, not full jq 1.6/GNU compatibility.
- **The phone is not a complete desktop POSIX host.** The Worker shell is
  `just-bash` with recorded deviations, not GNU bash/POSIX; there are no child
  processes and no general host shell. `workspace_command` runs `/bin/bash` on
  the host against a materialized copy and is therefore **host acceptance, not
  Worker evidence**; `worker_command` is the separate live-Worker acceptance.
- **JIT and memory behaviour on a device are unmeasured.** The probe numbers
  are macOS numbers and are not a device lower bound.
- **Keys and tokens are app responsibilities.** The app must supply a real
  `CredentialProvider`, a random per-launch loopback token and, for
  cold-process reclaim, a durable secure-vault `HandoffReclaimTokenStore`; the
  repository ships no keys, endpoints or accounts.

## Pointers

- [spec/v1](../spec/v1/README.md) — normative channel, WAL,
  exec, handoff and budget contracts, schemas and golden vectors.
- [plugins](../plugins/README.md) — Worker entry, channel library,
  plugins, phone profile, image packing and the desktop simulation.
- [docs/runbook-probe.md](runbook-probe.md) — build the
  artifacts, run the probe package and the smoke, read the reports.
- [docs/providers.md](providers.md) — provider protocols and the local phone
  harness rows.
