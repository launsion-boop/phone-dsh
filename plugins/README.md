# plugins — the DeepSeek Harness Worker path for the phone

MIT. This directory contains the TypeScript half of phone DSH: the ordered
channel codec and client, the Worker entry that boots the unmodified DeepSeek
Harness (DSH) runtime inside a WKWebView `Web Worker`, the DSH plugins and the
phone profile, the Worker shell and WASI toolbox, the image/profile tooling,
the compatibility suite, and a desktop simulation kept for development.

The App-process host is Swift and lives in
[`Sources/PhoneDSH*`](../Sources/PhoneDSH/PhoneDSHHost.swift).
The public overview is [docs/architecture.md](../docs/architecture.md); the wire
contract is [spec/v1](../spec/v1/README.md).

**Status: Worker path, macOS/Node only.** The landed suites here run under Node
on macOS; DSH runs in WKWebView on a phone, so **WKWebView, iOS Simulator and
device behaviour are `NOT_VERIFIED`**; see
[NOT_VERIFIED](#not_verified-needs-a-device). The numbers and timings in this
directory are Node/macOS numbers, never phone numbers.

## Contents

- [Layout](#layout)
- [How the Worker path fits together](#how-the-worker-path-fits-together)
- [Packages](#packages)
- [Worker profile](#worker-profile)
- [Image packing](#image-packing)
- [Desktop simulation](#desktop-simulation)
- [Development](#development)
- [NOT_VERIFIED: needs a device](#not_verified-needs-a-device)
- [Known limits](#known-limits)

## Layout

| Path | Package | Role on the Worker path |
|---|---|---|
| [`channel/`](channel/) | `@phone-dsh/dsh-channel` | `phone-dsh-v1` frame/WAL codecs, canonical JSON, CRC32C, ack tracker, `ChannelClient` and the WebSocket client; `MemoryChannel` for tests |
| [`worker-entry/`](worker-entry/) | `@phone-dsh/dsh-worker-entry` | the Worker entry: boots the pinned `webworker-runtime`, mirrors the VFS sink, serves `/api` requests over the channel, forwards console, bridges `/api/remote.mux`; `www/` is the minimal page, `src/web-boot.ts` boots the full DSH Web page over the runtime tunnel, and `build.mjs` emits the esbuild bundles plus the nested workflow isolate |
| [`workflow-worker/`](workflow-worker/) | `@phone-dsh/dsh-workflow-worker` | Worker-native `workflow-ptc` engine: official meta/execution semantics in a dedicated workflow Worker, the guest script in a QuickJS/WASM realm, real child agents over `ctx.subagents`, hard cancellation and realm-level synchronous deadline |
| [`exec-bridge/`](exec-bridge/) | `@phone-dsh/dsh-exec-bridge` | `ctx.xlExecBridge`: one client over `auto` transport (ordered channel, same-origin fetch, or `node:http` on the desktop), shared tool-call context, idempotency, path mapping |
| [`subprocess-xl/`](subprocess-xl/) | `@phone-dsh/dsh-subprocess-xl` | `ctx.subprocess` with the executor inversion (D12): `bash -c` and writers stay in the Worker; only advertised read-only accelerators become `EXEC_REQ`; `./sandbox` fails closed for modes the executor cannot confine |
| [`llm-bridge/`](llm-bridge/) | `@phone-dsh/dsh-llm-bridge` | model/MCP/web transport: a `node:http(s)` `fetch` for runtimes without WebAssembly, and the host `/v1/http` egress route that carries the host credential |
| [`tool-journal/`](tool-journal/) | `@phone-dsh/dsh-tool-journal` | durable tool-call journal, `XL_IDEMPOTENCY_KEY`, crash-only resume; `./persistence` is the JSONL session backend that reconciles on write-open |
| [`lifecycle-gate/`](lifecycle-gate/) | `@phone-dsh/dsh-lifecycle-gate` | pause/refuse new model requests and tool dispatches from the host push, long-poll, control file, boot state or in-process host; loop watchdog |
| [`surface-phone/`](surface-phone/) | `@phone-dsh/dsh-surface-phone` | the resident surface: webserver connection, token/cookie auth, `/api` RPC carrier, `XL_DSH_READY`; `mode: session-persistence` adapter for `tool-journal` |
| [`shell-ext/`](shell-ext/) | `@phone-dsh/dsh-shell-ext` | the Worker `bash` core (just-bash) over the VFS, the accelerator bridge, a `/v1/http` `curl`, output discipline and bounded capture |
| [`wasi-toolbox/`](wasi-toolbox/) | `@phone-dsh/dsh-wasi-toolbox` | WASI preview1 host, VFS proxy, warm instances; the `python3` runtime and the JavaScript `git` program |
| [`profile/`](profile/) | — | `phone.worker.cordis.patch.yml` (packed into the Worker image) and `phone.cordis.patch.yml` (desktop sibling) |
| [`scripts/`](scripts/) | — | pinned-checkout verifier, `pack-image.mjs`, `pack-overlay.mjs` and their tests |
| [`contract-tests/`](contract-tests/) | `@phone-dsh/dsh-contract-tests` | compatibility suite against the DSH seams, plus the daily master/pin diff |
| [`tests/`](tests/) | — | cross-package `node --test` suites (exec chain, image boot, inversion, pin consistency, seams, …) |
| [`tools/shell-corpus/`](tools/shell-corpus/) | — | the public shell corpus, classifier, extractor and coverage runner |
| [`sim/`](sim/) | — | the desktop simulation: reference exec bridge, scripted model, phone MCP stand-in, demo driver |
| [`bundle/`](bundle/) | — | the older single-file esbuild bundle and its native-module stubs, kept for the desktop simulation |

`plugins/package.json` is the workspace root: `channel`, `worker-entry`,
`workflow-worker`, `exec-bridge`, `subprocess-xl`, `llm-bridge`, `tool-journal`,
`lifecycle-gate`, `wasi-toolbox` and `shell-ext` are workspaces. `surface-phone` and
`contract-tests` are private packages that reuse the same `node_modules`;
`tests/`, `scripts/`, `profile/`, `sim/` and `bundle/` are not packages.

The DSH release is pinned in [`dsh-pin.json`](dsh-pin.json) (`0.2.1-rc.2`,
commit `7be5505`). Every workspace `@deepseek-ai/dsh-*` range must equal that
version, because DSH's app-boot compatibility preflight disables a plugin row on
any mismatch; [`tests/pin-consistency.test.ts`](tests/pin-consistency.test.ts)
enforces it.

## How the Worker path fits together

```
WKWebView web process
  page (www/index.html + www/boot.js)
    └── Worker (worker-entry.js)
          official DSH tree           official webworker-runtime
            subprocess-xl ──► Worker shell (shell-ext, just-bash) ──► VFS
            llm-bridge    ──► /v1/http on the loopback origin
            tool-journal  ──► session JSONL + journal in the VFS
            lifecycle-gate ◄─ LIFECYCLE/FENCE frames
          our entry: VFS sink (0x10) · API bridge (0x40–0x43)
                     console (0x60) · journal (0x30) · mux (D23)
                  │
                  │ one ordered binary WebSocket, same loopback origin
                  ▼
app process (Swift host)
  LoopbackServer · WorkspaceLog (WAL + materialized copy + overlay)
  ModelGateway · Controller · WebEngine · ExecProvider (PDSHShell)
```

`bash -c` and everything that can write runs in the Worker's shell. Only the
read-only accelerators that the host advertised in its `HELLO` caps
(`accelerator:<name>`) cross the channel as `EXEC_REQ`; their provider
(`PhoneDSHShell`) has no write operation. Model traffic never uses the
channel: `llm-bridge` calls the loopback `/v1/http`, which the Swift gateway
forwards with the app's credential.

## Packages

### `channel` — codecs and client

The byte-level implementation of `phone-dsh-v1` on the Worker side: the 16-byte
header, all 18 frame types, streaming decode (arbitrary chunk boundaries),
canonical JSON, CRC32C, WAL segment/record codecs and golden-vector tests
shared with the Swift codec. `MemoryChannel` is the in-process pair used by
tests and the desktop simulation; `WebSocketChannelClient` is the production
client, including reconnect and mseq re-send state.

### `worker-entry` — the Worker boot

`src/entry.ts` is driven by the page's `{t:'init', image, overlays, xl:{…}}`
message and follows a fixed order: create the channel and expose it before DSH
boots, connect and exchange `HELLO`, create the runtime host and start the tree,
subscribe the VFS sink and wrap `flush()` to wait for a level-1 ack, serve
`API_REQ` frames through the captured request listener, forward console lines,
mirror `LIFECYCLE`/`FENCE`, and post `pdsh-ready`. `src/runtime-binding.ts` is the
only module that imports the pinned runtime; the bundle resolves those imports
from `PDSH_DSH_CHECKOUT` at build time. `src/mux-bridge.ts` and
`src/mux-tunnel.ts` implement D23 (`/api/remote.mux` as unary channel requests
over the runtime's in-process stream lane), and `src/entry.ts` implements D22
(the `x-pdsh-channel-authenticated` marker: strip any inbound copy, then stamp
exactly one entry-owned value).

### `exec-bridge` — one exec client, three transports

A Cordis service shaped like DSH's `ctx.ssh`. On the phone Worker it selects
the ordered channel from `globalThis.__PDSH_CHANNEL__`; the same-origin `fetch`
and `node:http` transports remain for the desktop simulation and older hosts.
It exposes the shared tool-call `AsyncLocalStorage` under a global symbol, so
the packages stay independent, and it validates the host `HELLO` before any
caller becomes ready. Only explicit `spec.env` crosses the bridge; the
harness's own environment, including tokens, never reaches the guest.

### `subprocess-xl` — executor inversion

Cloned from DSH's `subprocess-ssh` structure: one handle per process,
collect-mode output through DSH's `OutputCollector`, `pipe`/`inherit` streams,
ordered stdin, provider-side termination, quiescence observed from the provider,
and re-attach with `after_seq` after a connection drop. On the Worker path the
handle is a `ShellWorkerProcess` over `just-bash`; only an advertised
accelerator becomes a channel `EXEC_REQ` with `requires_mseq` and `idem_key`.
A per-workspace mutex serializes executions so parallel sub-agents meet at
tool-call boundaries; the mseq revision is re-read when the slot is granted.
`spawnTerminal` (PTY) and the `control` channel fail loudly.

`./sandbox` (`XlGuestSandboxProvider`) never returns argv unchanged. For a
confined mode it prefixes a marker that `subprocess-xl` turns into the request's
`confine` field, only when the provider lists that mode; otherwise it throws
`SANDBOX_UNAVAILABLE`. An advertised accelerator is read-only by construction
and needs no confine wrapper.

### `llm-bridge` — model transport

On a runtime whose native `fetch` needs WebAssembly, `llm-bridge` installs a
`node:http(s)` fetch (`createNodeFetch`). The Worker path uses the host egress
instead: external model requests go to `/v1/http` with the channel bearer, and
the host gateway injects the real credential (the Worker sends its own
`Authorization` only as a placeholder that the host strips). It also covers MCP
over HTTP, because the same global `fetch` is used by DSH's MCP client.

### `tool-journal` — crash-only resume

Per top-level tool call: flush the session, journal `start` (durable), run the
tool inside the tool-call context carrying `XL_IDEMPOTENCY_KEY`, journal
`executed`, then `done` from `tools/result` before the agent loop appends its
`tool/result`. On the next `agent/pre-step` it compacts the journal. The
`./persistence` backend wraps the shipped JSONL session store and reconciles on
write-open: a call with `done`/`executed` is backfilled, a read-only or
idempotent call is re-run under the same key, and an unknown non-idempotent
outcome becomes `TOOL_OUTCOME_UNKNOWN`. The journal, not the session log, is
always at least as new.

### `lifecycle-gate` — admission and the loop watchdog

Gate points are `llm/stream` (before a model request) and `tools/execute`
(before a tool body), both after the session checkpoint. Sources, most
restrictive wins: the Worker push (`__PDSH_LIFECYCLE__` with `__PDSH_FENCE__`
admission), the bridge `GET /v1/lifecycle` long-poll fallback, a control file,
`PDSH_LIFECYCLE_STATE` at boot, and `ctx.xlLifecycle.set()`. `run` admits; `pause`
parks new work without interrupting in-flight work; `stop` refuses with the
non-retryable `PDSH_LIFECYCLE_REFUSED`. The watchdog refuses the N-th identical
consecutive tool call (default 3).

### `surface-phone` — the resident surface

Applied over `dsh-base` instead of `dsh-web-app`. It supplies `ctx.connection`,
the host launch-token and cookie authentication, the `/api` HTTP→Fetch carrier,
and the single `XL_DSH_READY` line. It reuses DSH's own host modules
(`dsh-host-webserver`, `dsh-api-remotes`, `dsh-api-session-controller`,
`dsh-client-file-upload`, `dsh-workspace`). In the Worker image the ordered
channel carries authentication: the entry stamps
`x-pdsh-channel-authenticated: 1` after stripping any inbound copy, and the
surface accepts that marker only when the process has the channel coordinates
the host injected (D24). The same package provides the
`mode: session-persistence` adapter that reconciles the JSONL backend against
`tool-journal` on write-open. The desktop carrier still requires the launch
cookie.

The worker image also carries the official browser client roster: the
`dsh-client-modules` host half composes `window.__DSH_BOOT__` from enabled
`dsh.client` rows and serves their bundles, while the UI rows cover the mobile
workbench, chat, sidebars, document/file/browser tabs, directory picker,
settings, references, jobs, schedule and plan surfaces. The xterm terminal tab
is off because iOS has no PTY; `phone-shell` registers the command console
(Worker bash over the VFS plus advertised read-only accelerators). The official
connection package is mounted as `connection-browser` so it contributes only
its browser bundle: its host half injects `webStartup` (never provided) and the
`credentials` row stays disabled, so it cannot register a second `/api`;
`surface-phone` remains the one host `ctx.connection`. The id is deliberately
not the global `connection` id, which app-boot requires to be active. iOS cannot
provide an OS process/PTY or LibreOffice conversion, so the terminal and Office
tabs stay present and report the real provider/runtime error instead of being
hidden or faked. The image packer asserts every `dsh.client` bundle is present
and that the boot graph is composable before it writes an image.

### `shell-ext` — the Worker shell

`bash -c` runs on just-bash over a `VfsFileSystem` that is the runtime's
`node:fs` (the in-memory VFS), so every write is a normal VFS mutation and
reaches the sink. Advertised accelerators inside a script call the exec bridge
with `requires_mseq` and `idem_key`; a name the host did not advertise stays
Worker-local. `curl` is the only network client and maps to `/v1/http`; other
methods or flags fail with exit 2. Output is capped by head and tail with the
elided byte count, and the environment is fixed (`TERM=dumb`, `NO_COLOR=1`,
`LANG=C.UTF-8`) so a model does not receive terminal formatting. Cancellation
is cooperative; wall-clock expiry returns 124, caller abort 130. The public
corpus is run by `tools/shell-corpus/coverage.mjs` (stub mode measures the shell
language and command table, not whether a package manager can install
anything).

### `wasi-toolbox` — WASI programs inside the Worker

A dedicated tool worker hosts a preview1 runtime. Modules compile once and stay
warm; every run gets a fresh instance and fd table. The VFS proxy resolves
preopened guest paths (`/workspace`, `/home`) to allowed host paths and has an
async `postMessage` transport and a `SharedArrayBuffer`/`Atomics.wait` sync
transport; without `crossOriginIsolated` and SharedArrayBuffer the sync path is
unavailable and file syscalls return `ENOTCAPABLE` rather than faking I/O.
`setWorkerToolbox()` is the integration point: the `python3` runtime calls it,
and the shell table then serves the toolbox's programs; the JavaScript `git`
program is in the default shell table without the toolbox. The Worker boot in
this tree does not install the toolbox, so `python3` is absent unless a host
wires it.

### `contract-tests` — the DSH seam suite

Runs against any DSH checkout: `createWorkerHost` option names, `MemoryVfs`
sink/flush semantics, `packVfsImage` options, `prepareProfile` merge order,
`PLATFORM_ENTRY_CONFIG`, overlay directory whitelist, `whenRequestListener`,
the `child_process` shim and shell program/interpreter tables, and the
workspace-changes git argv. It writes a canonical-JSON report with local paths
replaced by `<path>` and diffs a pin report against a master report. See
[`contract-tests/README.md`](contract-tests/README.md) and the daily
[`phone-dsh-compat`](../../.github/workflows/phone-dsh-compat.yml) workflow.

## Worker profile

[`profile/phone.worker.cordis.patch.yml`](profile/phone.worker.cordis.patch.yml)
is packed as the image's `home/cordis.patch.yml` and applied after `dsh-base`.
The desktop sibling [`profile/phone.cordis.patch.yml`](profile/phone.cordis.patch.yml)
is kept for the simulation and is not packed.

The Worker layer:

- replaces `subprocess` and `sandbox` with `subprocess-xl` and its
  `sandbox-xl` provider; no shipped provider is passed through unchanged;
- keeps `sandbox-policy` at `workspace-write` (overridable with
  `PDSH_SANDBOX_MODE`) and sets the `phone` permission preset (`workspace-write`
  + approval `never`; phone-side effects are approved by the app's MCP server);
- replaces the shipped JSONL session backend with
  `session-persistence-journaled` (`compression: none`) and keeps
  `session-query-sqlite` mounted with `openAt: never` because the Worker's
  `node:sqlite` is a structural mock;
- disables the host rows that need child processes, a package manager, a
  plugin tree, telemetry, `.env` credentials, host WebAssembly or the web
  frontend (`plugin-manager`, `ptc-runtime`, `otel`, `authorization`,
  `credentials`, `llm-pi-ai`, `web*`, `tool-web`, `pwsh-*`,
  `typert-loader`, …). The top-level `workflow-ptc`/`tool-workflow` host rows
  stay disabled because the official provider still needs a child process, but
  the static-module table serves that exact `workflow-ptc` specifier from
  [`workflow-worker`](workflow-worker/), so the standard/ptc presets mount
  their own `workflow-ptc` + `tool-workflow` rows over the Worker-native
  engine;
- inserts the host rows the Worker boot needs (`webserver`, `phone-surface`,
  `api-remotes`, `session-controller`, `file-upload`, `workspace`,
  `workspace-changes`) and our plugins (`subprocess-xl`, `sandbox-xl`,
  `session-persistence-journaled`, `pdsh-exec-bridge`, `llm-bridge`,
  `tool-journal`, `lifecycle-gate`, optional `mcp-phone`);
- normalizes the native-function `toString` spelling, because the JavaScriptCore
  engine WKWebView embeds prints `[native code]` across lines while DSH's
  tool-schema record check compares against V8's single-line form. This is a
  Worker-side compatibility shim in a profile config expression; it does not
  patch DSH source.

Environment the Worker plugins read. The Swift host injects the four D24
channel/launch values from the bound loopback listener; the rest come from the
app, the image or the shell defaults:

| Variable | Meaning |
|---|---|
| `PDSH_DSH_LAUNCH_TOKEN` | per-start token the resident surface consumes |
| `PDSH_CHANNEL_URL` | loopback URL of the ordered WebSocket channel |
| `PDSH_CHANNEL_TOKEN` | per-start bearer for that channel |
| `PDSH_CHANNEL_ORIGIN` | loopback origin of `/v1/http` and the static routes |
| `PDSH_DSH_PORT` | surface loopback port (`0` in the Worker; the carrier is virtual) |
| `PDSH_LIFECYCLE_FILE` | optional lifecycle control file |
| `PDSH_SANDBOX_MODE` | default `workspace-write` |
| `PDSH_PHONE_MCP_URL`, `PDSH_PHONE_MCP_TOKEN` | optional app MCP endpoint |
| `DSH_HOME` | virtual home (`<root>/home` by default) |
| `PDSH_SHELL`, `PDSH_SHELL_TIMEOUT_MS`, `PDSH_SHELL_MAX_OUTPUT_BYTES`, `PDSH_THERMAL_STATE` | Worker shell core and limits |

## Image packing

[`scripts/dsh-checkout.mjs`](scripts/dsh-checkout.mjs) verifies the pinned
checkout (HEAD, tracked tree, untracked files under roots the packer reads,
runtime and packer build artifacts). The path comes from `PDSH_DSH_CHECKOUT` or
the per-machine file; it is never written into the repository.

[`scripts/pack-image.mjs`](scripts/pack-image.mjs) stages every workspace
package (esbuild bundles each source export face to `lib/*.js`, rewrites
`exports`, keeps non-code faces), asks the pinned checkout's own
`packVfsImage` for the image with `PackOptions` (`profile`, `roster`,
`installation`, `workspaces`, `resolveFrom`, `homePatch`, `entries`), applies
`profile/phone.worker.cordis.patch.yml` as the home patch, and asserts the
image is complete (every staged face present, no export face lowered twice, no
phone-dsh export face left in the page-bundle set). Outputs:

| File | Contents |
|---|---|
| `image.tar.gz` | gzip-compressed ustar base image returned by the pin's packer |
| `lazy/<sha256>.tar.gz` | lazy page-chunk archives (empty for the phone roster) |
| `manifest.json` | the image's `config/vfs-manifest.json` |
| `worker.js`, `client.js` | runtime Worker assembly and page tunnel client from the pinned checkout |
| `sizes.json` | `raw_bytes`, `gzip_bytes`, per-lazy sizes, file count, pin version/commit |

[`scripts/pack-overlay.mjs`](scripts/pack-overlay.mjs) packs a data overlay:
only `home/` and `workspace/` at the top level, no symlinks or special files,
sorted ustar with normalized modes and mtime 0. The host packs a fresh overlay
per boot from the materialized copy plus the WAL tail.

The profile-patch tests (`scripts/profile.test.mjs`) and the image tests
(`scripts/pack-image.test.mjs`) run with `node --test scripts/`.

## Desktop simulation

[`sim/`](sim/) plays the app on a Mac: `exec-bridge-sim.mjs` implements
exec-bridge v1 over a workspace directory, `mock-llm.mjs` is a scripted
Messages-compatible model (no network, no credentials; the API key is a
placeholder), `phone-mcp-sim.mjs` stands in for the app's MCP server, and
`run-demo.mjs` copies the bundle to a temporary directory before running a
task. [`bundle/`](bundle/) builds the older single-file bundle that simulates
the nodejs-mobile-style host; it is not part of the Worker path. The desktop
profile is [`profile/phone.cordis.patch.yml`](profile/phone.cordis.patch.yml).
Desktop results are development signals only; they are not phone numbers.

## Development

```sh
cd plugins
npm install --ignore-scripts    # dependencies from package-lock.json (no network additions)
npm run typecheck               # tsc against DSH's published .d.ts
npm test                        # node --test: channel, worker entry, tests/, wasi-toolbox, scripts, corpus
npm run contract -- --checkout "${PDSH_DSH_CHECKOUT:-$(sed -n '1p' "$HOME/.config/phone-dsh/dsh-checkout")}"
npm run contract:diff -- pin.json master.json --out reports/
npm run bundle                  # desktop bundle only
npm run sim                     # reference exec bridge
npm run demo                    # scripted desktop task
```

`npm test` and `npm run typecheck` require `node_modules` (and, for the image
tests, the pinned checkout's build artifacts). A missing checkout is a skip
only where the test explicitly says so; a missing build output is a failure.
The daily workflow `.github/workflows/phone-dsh-compat.yml` builds the pinned
checkout and runs `npm run contract` against the pin and master, then runs the
`phone-plugins` CI stage on macOS.

## NOT_VERIFIED: needs a device

- **WKWebView execution.** The official runtime as a WKWebView `Web Worker`:
  module loading, the captured `node:http` listener, timer throttling under a
  one-point visible attachment, the same-origin fetch and WebSocket behaviour,
  and WebContent termination/restart. All of the tests here run under Node.
- **JavaScriptCore compatibility** beyond the macOS probe: the native-function
  `toString` form, `Symbol.dispose`/`Symbol.asyncDispose`, async iteration over
  `ReadableStream`, and any other engine-specific gap.
- **On-device JIT and memory.** The JavaScriptCore/WKWebView benchmark, jetsam,
  WebContent memory growth over a long session, and the budget ceilings are
  unmeasured on a phone.
- **Background scheduling.** `BGContinuedProcessingTask`, `isIdleTimerDisabled`,
  scene-phase draining and the two-tier promise are policy logic tested on
  macOS; the OS actually scheduling them is unverified.
- **Native accelerators.** The linked pdsh-shell XCFramework is opt-in
  (`PDSH_WITH_XZSHELL=1`) and not built here; the provider's stub advertises
  nothing and fails loudly. The Rust library does not register the six public
  commands yet.
- **WASI file syscalls.** The synchronous `SharedArrayBuffer` path depends on
  `crossOriginIsolated` on the phone origin; only the async control plane is
  exercised on macOS. `python3` and `git` inside the Worker are unverified on
  device, and the Worker boot in this tree does not install the toolbox (see
  the package section above).
- **The real remote handoff endpoint.** The client, applier and coordinator are
  tested against an in-process simulator; a remote DSH host and the phone's
  facade-level handoff entry point are not part of this tree.
- **The phone MCP server.** The simulation stand-in is not the Swift SDK's MCP
  server; the loopback bearer path on a device is unverified.

## Worker image boot test (DSH 0.2.1)

[`profile/phone.worker.cordis.patch.yml`](profile/phone.worker.cordis.patch.yml) is the phone
layer packed into the Worker image as `home/cordis.patch.yml`; `scripts/pack-image.mjs` stages the
repository plugins, calls the pinned checkout's own packer, and asserts every staged export face
was lowered. The npm manifests stay on the same release as [`dsh-pin.json`](dsh-pin.json):
`tests/pin-consistency.test.ts` fails if any workspace `@deepseek-ai/dsh*` range differs from the
pin, because app-boot's compatibility preflight disables a plugin row on any mismatch.

[`tests/image-boot.test.ts`](tests/image-boot.test.ts) proves the packed image boots. It packs the
image into a temporary directory, bundles [`tests/fixtures/worker-boot-harness.ts`](tests/fixtures/worker-boot-harness.ts)
against the checkout's webworker-runtime sources, and runs it under Node with the phone profile and
a stubbed ordered channel (host HELLO, monotonic `mseq`, `PDSH_DSH_LAUNCH_TOKEN`, `PDSH_CHANNEL_URL` /
`PDSH_CHANNEL_TOKEN`). The harness applies the Worker entry's profile stub overlay — the same bytes
`startPhoneWorker` passes to the runtime — and reproduces the native-function source format
observed from the system JavaScriptCore (`function Object() {\n    [native code]\n}`); on-device
WKWebView is NOT_VERIFIED.

[`tests/workflow-worker.test.ts`](tests/workflow-worker.test.ts) builds the same isolate from the
pinned checkout and runs real scripts in `worker_threads`: constructor/dynamic-import/EventSource
escapes against parent sentinels, the child bridge, fatal-error identity, a QuickJS-enforced
synchronous deadline with a successful next run, and cancellation/child cleanup. A second fixture
imports the built `workflow-isolate.js` with a browser-like `postMessage`/`addEventListener` pair so
the production browser transport path is covered. [`tests/browser-isolate.test.ts`](tests/browser-isolate.test.ts)
is the optional real-browser gate (`PDSH_CHROMIUM=/path/to/chrome`); it loads the production bundle
in Chromium and runs a standard workflow plus a hard-stopped loop. It is skipped by default because
Playwright's browser download is not part of `npm ci`; the Mac WKWebView/JavaScriptCore simulator
gate remains the authoritative on-device check.
The test passes only when:

- no roster row is disabled by the app-boot compatibility preflight;
- no tool row raises `authorError` / `JsonSchemaError` from the 0.2.1 schema compiler;
- no runtime module proxy reports a not-implemented feature (`notImplementedFail`);
- every non-documented-pending roster row activates; the only allowed
  `entries did not activate` detail is the existing `connection-browser`
  pending warning (browser `webStartup`/`credentials` not provided);
- no console line is logged at error level, except the documented
  pending-roster warning and the minimal preset's real
  `terminal: Error: the phone Worker has no terminal (PTY) primitive` refusal;
- the surface emits `XL_DSH_READY <port>`.

Two 0.2.1-only compatibility layers live in the profile:

- **Native-function source normalization.** DSH 0.2.1's plain-JSON record check
  (`packages/core/tools/src/json-schema.ts`) compares `Function.prototype.toString` against the V8
  single-line spelling. The system JavaScriptCore prints a multi-line spelling (on-device
  WKWebView NOT_VERIFIED), so every tool schema is rejected before its plugin gate: the record
  test fails, `runSchemaCompiler` (`packages/core/tools/src/schema.ts`) raises the
  `... must be an object of value schemas` `authorError`, and the row never mounts. The profile's
  `tools` row config runs a small expression that normalizes only the native-function form, before
  any tool row mounts.
- **Session persistence adapter.** 0.2.1's `session-persistence-jsonl` is a function plugin with a
  private service class, so the 0.1.7 subclass in `tool-journal/src/persistence.ts` cannot mount.
  The `session-persistence-journaled` row uses `surface-phone`'s `mode: session-persistence`
  adapter, which mounts the shipped backend and wraps `open()` to reconcile write handles against
  the tool journal. The legacy subclass source is no longer mounted by either phone profile; it
  stays in the package (rewriting it is outside this work package's write scope) and is
  type-shimmed by `tests/legacy-persistence-types.d.ts`.

Two more compatibility layers live in the Worker entry
([`worker-entry/`](worker-entry/)):

- **JavaScriptCore prelude.** WKWebView's engine lacks `Symbol.dispose` /
  `Symbol.asyncDispose` (lowered `using` throws at session creation) and async iteration over
  `ReadableStream` (SSE reads fail as TRANSPORT). `worker-entry/src/jsc-compat.ts` installs both
  plus the `Promise.withResolvers` fallback needed by the iOS 17.0 deployment floor,
  feature-detected and idempotently, before any DSH module evaluates. `build.mjs` uses
  `src/boot.ts` as its bundle root, which imports the prelude first; the macOS smoke's prepended
  copy is therefore redundant (a follow-up removes it). On-device behaviour is NOT_VERIFIED.
- **Clean profile boot.** The image records the shipped `web` template, whose bundle list names the
  `dsh-web-app` application the image deliberately does not materialize; app-boot reports that
  bundle as skipped at error level on every boot.
  `worker-entry/src/profile-overlay.ts` supplies the minimal `home/profiles/web/package.json`
  overlay whose bundle list names only `@deepseek-ai/dsh-base`. The browser client roster is packed
  as ordinary home-patch rows, but no `dsh-web-app` bundle or `web-runtime` row is materialized and
  no DSH source is patched; the overlay is applied before deployment overlays, which still win.

This test runs the Worker runtime under **Node**, not WebKit: on-device/WebKit execution remains
**NOT_VERIFIED** (see below), and the image-boot test is a compatibility check of the image and
plugin layer, not a substitute for the macOS/iPhone smoke rehearsal.

## Known limits

- File-tool reads are not confined to the workspace by DSH's `workspace-write`;
  only writes are. Keep secrets in the Keychain and out of files the model can
  read.
- `spawnTerminal` (PTY), the subprocess `control` channel and native addons are
  not available.
- A command orphaned by a harness crash keeps running until it ends; the host
  caps runtime through the accelerator limits.
- The journal keeps tool results until the next step compacts it; the quota is
  enforced by the Swift host in production.
- `PDSH_JOURNAL_FAULT` and the simulation stubs are test hooks; never set them in
  a deployment.
- The Worker image is under the pinned checkout's licence terms (MIT for DSH;
  the third-party table is [`THIRD_PARTY.md`](THIRD_PARTY.md)). Nothing here is
  GPL, and no `@deepseek-ai/*` source tree is patched or vendored. The packer
  normalizes exactly two built Cordis `dispose()` call sites (see
  [`scripts/README.md`](scripts/README.md#cordis-disposal-compatibility)).
