# `@phone-dsh/dsh-worker-entry`

The Worker shell for DeepSeek Harness on the phone. It boots the unmodified
pinned runtime over a packed image, mirrors the in-memory VFS over the ordered
channel, serves the host's `/api/*` requests, and forwards console output to
the host app.

This package is the only place that adapts DSH's browser-facing carriers to
the phone's ordered channel. It imports the pinned checkout; it never patches
or copies it.

## Layout

| File | Purpose |
|---|---|
| `src/entry.ts` | Boot order, VFS sink, API request bridge, console forwarding, LIFECYCLE/FENCE mirroring |
| `src/boot.ts` | Bundle root: imports the JavaScriptCore prelude before the entry graph, then re-exports the entry |
| `src/web-boot.ts` | Full DSH Web page half: spawns `worker-entry.js`, captures the init query in memory, scrubs its transport keys from the visible URL, drives the runtime `WorkerTunnel`, installs the transport globals and applies the boot injection table |
| `src/jsc-compat.ts` | Feature-detected, idempotent JavaScriptCore compatibility prelude |
| `src/promise-compat.ts` | Feature-detected `Promise.withResolvers` fallback for the iOS 17.0 deployment floor |
| `src/namespace-boot.ts` | One path authority: `/tmp` ↔ `/dsh/tmp`, root seeding, the exec read policy and the bounded opener hook |
| `src/bounded-opendir.ts` | Capture-only bounded opener beside a transparent virtual `node:fs.promises.opendir`; counts `usage()` plus lazy registrations before a Worker command capture can materialise an oversized directory |
| `src/capabilities.ts` | Boot-time environment priors: `AGENTS.md` + `capabilities.json`, enumerated commands, limits, egress, idempotent publish |
| `src/profile-overlay.ts` | Minimal profile-manifest overlay that keeps app-boot from skipping the absent `dsh-web-app` bundle |
| `src/python-toolbox.ts` | Production wiring of the W7 CPython-on-WASI runtime: reads the image artifacts, builds `PythonRuntime`, publishes the toolbox |
| `src/runtime-binding.ts` | The single module that imports the pinned webworker runtime |
| `src/module-import.ts` | Controlled type/code/specifier/static-location diagnostic for image-module import failures (JSC stacks omit the message); raw message, stack, cause and custom fields are never forwarded |
| `src/static-modules.ts` | The runtime's static-module table with this layer's overrides (`sharp`, `app-boot`, Worker `workflow-ptc`, `tool-presentation`, `node:vm`, terminal refusal) |
| `src/vm-shim.ts` | Compile-only `node:vm` face for the DSH Worker's parent-side workflow syntax check; scripts never execute there |
| `src/tool-presentation-shim.ts` | `tool-presentation` row: real native tools when PTC is unavailable, no fabricated PTC |
| `src/module-shim.ts` | `node:module` wrapper that gives static image package overrides real manifest search paths |
| `src/terminal-shim.ts` | Loud phone refusal for the official persistent-terminal provider (no PTY) |
| `src/fs-read-state.ts` | Durable read-state replay mounted through the app-boot shim (G2-FIX-36) |
| `src/sharp-shim.ts` | Worker-side `sharp` subset: container metadata, raster decode, normalization pipeline |
| `src/sharp-metadata.ts` | Pure-TS PNG/JPEG/GIF/WebP header inspection used by the shim |
| `src/sharp-jpeg.ts` | Strips WebKit-added retained metadata from JPEG encoder output without touching scan data |
| `src/sharp-errors.ts` | Distinct malformed-input, unsupported-operation and encoder-output errors |
| `src/sharp-marker.ts` | Bundle/pack identity marker for the shim |
| `src/runtime-modules.d.ts` | Structural declarations for the runtime sources the entry calls |
| `src/mux-bridge.ts` | Worker-side `/api/remote.mux` protocol bridge (D23) |
| `src/mux-tunnel.ts` | Production mux sessions over the runtime's in-process stream lane |
| `src/fixtures/` | The stubbed-global child process the prelude tests run |
| `build.mjs` | esbuild bundles from the pinned checkout: `worker-entry.js` (root `src/boot.ts`), the `tool-worker-python.js` the python runtime spawns, the dedicated `workflow-isolate.js`, and the page-side `web-boot.js` |
| `www/` | Minimal boot page that starts the Worker and posts `init` (the full DSH page uses `web-boot.js`) |

## Full Web page boot

The full DSH Web client is served from `Bundle/worker/web/` (built by
`scripts/ci/build-web-dist.sh`). `src/web-boot.ts` is the page half that connects
it to the same phone Worker:

- it reads the page query (`image`, `channel`/`channelURL`, `token`, repeated
  `overlay`, JSON `fence`/`env`/`egress`, `boot_id`/`session_epoch`) and posts
  the exact `{t:'init', image, overlays, xl:{channelURL, token, env, fence,
  bootId, sessionEpoch, egressAllow}}` frame `www/boot.js` posts;
- it spawns `new Worker(new URL('../worker-entry.js', import.meta.url),
  {type:'module'})` and uses the pinned runtime's `WorkerTunnel` directly
  (`connectWorkerHost` cannot carry the phone's `xl` coordinates);
- after `tunnel.bootPayload()` it installs
  `__DSH_TRANSPORT__ = {fetch, openStream, loadBundle, ownsHost:true}` and
  `__DSH_FILE_UPLOAD__ = {fetch}`, applies the injection table through
  `applyIndexInjections(payload.injections, src => tunnel.loadBundle(src))`,
  sets `document.title = 'DSH ready'` (the existing native `WebEngineScripts`
  ready signal, because the full page has no `#status`), and only then resolves
  the already-installed `__DSH_BOOT_READY__` deferred;
- a failed handshake rejects that deferred with a new bounded, redacted
  `Error` and appends a visible error panel instead of letting the client entry
  run on missing globals; the raw reason (whose 503 body can repeat the token
  and env) is never thrown or retained as `cause`;
- the pinned `WorkerTunnel` warns the raw 503 `message` on `console.warn`
  before the rejection is observable, and `WebEngineScripts` forwards that line
  to the native log. The page installs a console redactor for the boot window
  before constructing the tunnel and restores the original methods afterwards;
- a Worker can fail before `createWorkerHost` exists (invalid `fence`, runtime
  load, profile/overlay creation). The page keeps one control-frame filter ahead
  of the tunnel for its lifetime, so `pdsh-ready`, `pdsh-error`, `init-error`,
  `pdsh-boot-error` and any other out-of-band frame never reach the tunnel's
  unknown-frame path; the failure frames reject the readiness gate with bounded,
  redacted copy, and the Worker outer boot catch posts that terminal frame for
  pre-host failures. One deadline (240 s default, test/caller override) and one
  abort cover the whole ready phase — `bootPayload()` plus
  `applyIndexInjections`/`loadBundle` — so a silent Worker or a bundle request
  that never answers settles readiness instead of leaving it pending;
- the boot coordinates are one-shot: immediately after they are parsed and
  before the Worker is spawned, `history.replaceState` removes every transport
  key (`image`, `channel`/`channelURL`, `token`, `overlay`/`overlay[]`,
  `fence`, `env`, `egress*`, `boot_id`/`bootId`, `session_epoch`/
  `sessionEpoch`) from the visible URL. Business query entries and the hash are
  preserved. The parsed values stay in memory for the `init` frame and are
  never written to `history.state` or storage, so a copied link, a saved route
  or a screenshot carries no launch token;
- a boot failure shows normal user copy plus a length-bounded technical detail
  whose transport values are redacted by both field shape and the exact
  token/env/image/overlay values captured from the init frame;
  `bootWebWorker` logs the same sanitized detail, and the Worker entry's
  `reportPageError`/`bootFromInit` path redacts before a CONSOLE frame can reach
  the Native app log.

This adds no `/api` or `/api/remote.mux` proxy, no WebSocket chat protocol, no
remote URL and no second session: all page traffic is the runtime tunnel to the
existing Worker host, whose `TunnelServer` serves `/__boot__`, `/api` and the
mux lane. The app must point its page at `/static/web/index.html` (a separate
WKWebView container task); file presence alone is not Web-session proof.

`www/boot.js`, the minimal page used by the image/probe harness, applies the
same capture-then-scrub and redaction rules. `scripts/ci/build-web-dist.sh`
also injects a `Promise.withResolvers` fallback before the full client tree,
because Safari only shipped that method in 17.4.

## Worker-side `sharp` (G2-FIX-60)

DSH's `attachment-local` decodes rasters through
`createLazyRequire('sharp')`. The pinned runtime lists `sharp` in
`REPLACED_EXTERNAL_PACKAGES` and serves a `notImplementedFail` stub from
`MODULE_PROXIES`; `image.ts` then folds the stub's refusal into
`INVALID_IMAGE`, so every valid PNG/JPEG/WebP/GIF looked malformed and each
`read_image` call burned a model request.

`src/static-modules.ts` overrides the exact `sharp` entry in the table
`createNodeBuiltins()` returns (the table also carries the app-boot shim
described below), and `src/runtime-binding.ts` hands that table to
`createWorkerHost`. The runtime's loader checks the exact-specifier table before
filesystem resolution, so `require('sharp')` inside the packed image resolves to
`src/sharp-shim.ts`; the image still omits the native package. `build.mjs`
applies the same redirect to statically bundled importers and fails when the
shim's marker is missing from the emitted bundle; `scripts/pack-image.mjs`
asserts the runtime still replaces `sharp` and records the replacement in
`sizes.json`.

Implemented sharp surface (everything the bundled attachment code reaches):

- `sharp(bytes, { failOn, limitInputPixels })`, `.metadata()` from container
  headers only (no pixel decode);
- `.raw().toBuffer()` through the Worker's `createImageBitmap` and
  `OffscreenCanvas` primitives, returning RGBA at the stored dimensions;
- `.rotate()`, `.toColourspace('srgb')`, `.resize({ fit: 'inside' })`,
  `.clone()`, `.jpeg()`, `.webp()`, `.png()` and
  `.toBuffer({ resolveWithObject: true })` for attachment normalization and the
  request-image quality ladder.

Anything else throws `SharpUnsupportedOperationError` with
`code: 'SHARP_UNSUPPORTED_OPERATION'` and the operation name; malformed bytes
throw `SharpInputError` (`SHARP_INVALID_IMAGE`), which admission maps to its own
`INVALID_IMAGE`. EXIF orientations 2-8 are applied with a canvas transform when
`.rotate()` runs. WebKit's `createImageBitmap` orientation-option behaviour and
`OffscreenCanvas` WebP encoding are `NOT_VERIFIED` on device; a runtime that
cannot encode WebP gets the loud unsupported-operation error instead of a
silently mislabelled image.

WebKit's `OffscreenCanvas` JPEG encoder can append an APP1 `Exif\0\0` segment
and an APP13 `Photoshop 3.0\0` segment to an otherwise metadata-free canvas.
DSH's normalization policy reads the real output bytes and rejects retained
metadata, so `src/sharp-jpeg.ts` removes exactly the segments
`sharp-metadata.ts` reports (APP1 EXIF/XMP, APP2 ICC, APP13 Photoshop/IPTC and
COM comments) after encoding. APP0/JFIF, APP14/Adobe and every scan byte,
`FF 00` stuffing and restart marker are preserved; APPn segments outside that
policy are left alone. A truncated segment, invalid length or broken marker
raises `SharpEncoderOutputError` (`SHARP_ENCODER_OUTPUT`) instead of emitting a
corrupt JPEG.

`tests/sharp-shim.test.ts` packs the image, bundles the real Worker runtime
sources, and drives attachment-local's admission through both the runtime table
(the pre-fix `INVALID_IMAGE` result) and the composed table (canonical 68-byte
1x1 PNG, two-frame GIF, clean JPEG, and corrupt bytes).
`tests/sharp-jpeg.test.ts` covers the WebKit-shaped APP1/APP13 fixture, scan
preservation and malformed encoder output.

## Read-state restore across park/resume (G2-FIX-36)

DSH's `@deepseek-ai/dsh-fs-observation-policy` keeps its read-before-write
state in an in-memory `WeakMap` keyed by the live agent session, and the pinned
package documents that observations do not survive a session resume. A
park/resume rebuilds the Worker, so a session resumed from its durable JSONL
log started with no observations: the first `write`/`edit` of a file read in an
earlier turn was refused with `file has not been read — read the file, then
retry`, forcing the model to re-read the whole turn's targets.

`src/fs-read-state.ts` is the worker-entry shim. `src/static-modules.ts`
overrides `@deepseek-ai/dsh-app-boot` with a module that wraps only `boot()`:
before the launcher's own prepare step it mounts one extra plugin
(`pdsh-fs-read-state`) on the host context, then forwards everything else. The
pinned app-boot is loaded from the image by package directory, so no DSH source
is copied or patched. The policy module and its profile row are untouched —
replacing that specifier would hide its `package.json` from the profile
compatibility preflight, which resolves every row through
`createRequire.resolve.paths`. The replay:

- mirrors live `fs/observed` events, so an observation made in the current
  Worker is always authoritative and is never replaced by the durable log;
- captures the versions when an agent/session is published (the resume
  boundary), before the rebuilt Worker runs a command, and replays the
  successful observing calls (`read`, `read_image`, `write`, `edit`) from that
  session's `snapshotEvents()` as ordinary `fs/observed` events;
- repeats the replay lazily before the first `fs/write-intent` /
  `fs/edit-intent` if the resume listener fired before the fs service was
  mounted, then delegates the decision to the pinned policy through the
  waterfall's `next()`;
- never observes a target the session did not read or write, so an unread file
  is still refused by the provider exactly as before.

The durable tool result does not carry the provider's opaque version token, so
the replayed observation uses the target's current version. The provider still
fences changes concurrent with the resumed write; a change that happened
between the original read and the rebuild cannot be detected from the log
alone. This is the upstream contract gap behind the shim (no persisted
observation records and no restore hook); a future upstream restore API should
replace it.

## Command-boundary durability

The VFS sink is asynchronous: a committed `MemoryVfs` mutation becomes a 0x10
frame, the host appends it to the WAL and materializes it, then the level-1
0x11 ack comes back. A command that returns before that ack can lose its last
writes to a WebContent kill even though it reported success (G2-FIX-61).

The entry installs one fence after `installSink`: the sink-wrapped
`vfs.flush()` is published as the Worker global `__PDSH_VFS_FLUSH__`
(`WORKER_VFS_FLUSH_GLOBAL`), removed by the same disposer chain, and awaited by
`subprocess-xl` before a Worker shell command reports its exit. The WASI toolbox
reaches the same fence through `NodeFsBackend.sync`. `handle.stop()` first
hard-stops any active WASI dispatch (`toolbox.terminate('drain')`), then flushes
once while the channel is still live, before the disposers detach the sink, so
an orderly park neither waits for a wedged interpreter nor leaves accepted
writes unacknowledged (G2-FIX-104).

## Proxied-write outcomes (G2-FIX-103)

The command fence is not enough for a single WASI write. `startPhoneWorker`
also creates one `VfsWriteOutcomes` per boot and shares it between the sink and
the WASI VFS backend:

- the sink attaches each published `VFS_MUT` (`notePublished`), forwards every
  `0x11`/HELLO ack (`noteAck`), forwards a host `ERROR VFS_REFUSED`
  (`noteRefusal`, idempotent per `(mseq, path)` because a parked `flush()` sees
  the same diagnostic again while a refusal of the write renumbered into that
  slot names its own path and still settles it) and fails every pending ticket
  when the sink fails loud or is disposed;
- the backend awaits the ticket inside the guest's `write`/`truncate`, so the
  proxy answers with an errno instead of success before the host decided. A
  refusal becomes `EFBIG`/`ENOSPC`/`EDQUOT` with the limit and a split/chunk
  remediation on the command's stderr; a D3 flow-control stall (default 30 s,
  `VfsSinkLimits.flowControlTimeoutMs` / `PDSH_VFS_FLOW_CONTROL_TIMEOUT_MS`)
  becomes the typed `VfsFlowControlError` without closing the channel;
- the sink-wrapped `flush()` throws an already-failed flow-control error
  instead of waiting a second window, so the tool call settles promptly.

`PhoneWorkerHandle.writeOutcomes` exposes the tracker for diagnostics and the
component tests.


## JavaScriptCore compatibility prelude

JavaScriptCore (the engine WKWebView embeds) lacks four platform features DSH
0.2.1's lowered code or its npm dependencies rely on:

- `Symbol.dispose` / `Symbol.asyncDispose`, used by lowered `using` /
  `await using`; without them session creation throws
  `TypeError: Symbol.dispose is not defined`;
- async iteration over `ReadableStream`, which the DeepSeek adapter uses to read
  SSE in a `for await` loop; without it every model request fails as a
  TRANSPORT error;
- `Promise.withResolvers`, which the pinned runtime and DSH's agent loop use
  while starting a session (installed by `src/promise-compat.ts`); and
- Node's `global` alias, which a Web Worker does not define and which
  Node-style npm packages read while their module body evaluates (for example
  the `isexe` probe reached through the official MCP SDK's stdio import).

`src/jsc-compat.ts` installs all four. The installer is:

- **feature-detected** — an existing definition (Node, modern engines, a newer
  WebKit) is never touched;
- **idempotent** — a second import or call adds nothing;
- **keyed by `Symbol.for`** — `xl.symbol.dispose` / `xl.symbol.asyncDispose`,
  the same values the macOS smoke prelude uses;
- **installed before the entry graph** — `src/boot.ts` imports it first and
  `build.mjs` uses that root, so the emitted `worker-entry.js` installs it
  before any DSH module evaluates. `src/entry.ts` imports it first as well, for
  callers that import the entry module directly.

`Promise.withResolvers` is feature-detected too (Safari 17.4 was the first
WebKit release with the method; the deployment floor is iOS 17.0). The page side
gets the same fallback from `src/promise-compat.ts` and the `build-web-dist.sh`
prelude before the full DSH client evaluates.

`src/jsc-compat.test.ts` covers the installer, runs the entry in a child process
whose `Symbol` and `ReadableStream` lack the features, and repeats that against
the built bundle; the same child deletes Node's `global` before the entry
evaluates. WebKit/on-device behaviour remains `NOT_VERIFIED`; the tests run
under Node.

## Clean profile boot

The packed image records DSH's shipped profile template `web`, whose bundle list
is `["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]`. The image
deliberately does not materialize the `dsh-web-app` bundle or its `web-runtime`
host row, so app-boot reports the unreadable bundle as skipped
(`dsh: skipping profile bundle ...`) on every boot at error level.

`src/profile-overlay.ts` supplies the minimal data overlay that removes the
report: a `home/profiles/web/package.json` manifest whose bundle list names only
`@deepseek-ai/dsh-base`. The image does carry the official browser client
roster (including `dsh-client-modules` and `dsh-client-connection`'s browser
bundle) as ordinary home-patch rows, but not the `dsh-web-app` application
bundle; no DSH source is patched or copied. The overlay is a gzip member holding one ustar file; the
runtime's `readImage` accepts the same envelope for data overlays as for the
base image. It is applied before every deployment-supplied overlay, so a later
overlay still wins. `src/profile-overlay.test.ts` checks the manifest, the ustar
entry and the gzip envelope, and cross-checks the template name against
`IMAGE_PROFILE` in `scripts/pack-image.mjs`.

## Path authority install

The first thing after `host.start()` and before any `API_REQ` is
`installNamespaceAuthority()` (`src/namespace-boot.ts`). It wraps the mounted
VFS with `createNamespaceVfs()` so `/tmp/**` and `/dsh/tmp/**` are one storage
path for every `node:fs` caller, publishes that wrapper as the runtime's active
VFS, creates the namespace roots (the volatile root with mode `0o1777`
requested) and probes both volatile spellings. A probe failure is a loud boot
failure: the upstream sandbox grants both `/tmp` and `os.tmpdir()`
(`/dsh/tmp`), and a surface that cannot see one of them is exactly the G2-D05
defect. The same step patches the shared `node:fs.promises` object with the
exec read policy, so the shell and git refuse DSH session state with `EACCES`.

Immediately after the policy, `installBoundedDirectoryOpener()` wraps the same
object's `opendir`. The shared member stays transparent for ordinary DSH,
session and storage reads; it exposes a separate bounded opener function that
only the Worker command capture calls. The pinned runtime's `opendir` builds the
complete listing synchronously, so that function verifies the mounted VFS's
public `usage()` plus the initial lazy registrations named by the pinned image
manifest and any later public `deferArchive()` calls, then refuses when the
conservative sum exceeds the capture's 20 000-entry default. The capture also
passes its phase deadline/abort check into the bounded call; the bridge runs it
once before and once after its synchronous scans, then refuses before the
original opener if the post-scan check fails. Below the bound it calls the
original opener in the same synchronous stack, with no `await` for a writer to
interleave. This is bounded materialisation, not a streaming enumerator: the
`/tmp` alias and the private-namespace refusal still come from the policy layer
underneath, and the host's real Node `fs.promises` is never patched. See
the plugin tests.

## Environment priors (G2-ENG-05)

Before the first `API_REQ` the entry publishes two files into the persisted
home: `/dsh/home/AGENTS.md` (≤ 4 KiB) and `/dsh/home/capabilities.json`
(`schema: pdsh-capabilities/1`). The upstream `agent-instructions` row — inherited
unchanged from `dsh-base` — injects `$DSH_HOME/AGENTS.md` as the user-global
instruction chain, so the model starts with the command table, Python modules
and gaps, budgets, egress allow-list, `/tmp` semantics, the recorded bash
deviation (ENG-02 `JB-EPOCHSECONDS`; `trap` is a real EXIT-only builtin) and
restart rules instead of discovering them with probe requests (the
G2-A05/A06 overrun).

`src/capabilities.ts` keeps this truthful rather than hand-written:
`workerCommandSurface()` enumerates just-bash's registry plus
`createWorkerCommands()` (Worker programs, `curl`, the WASI toolbox and the
host HELLO accelerators); `python_modules[]` is the build-time probe
`scripts/pack-image.mjs` stages beside CPython; `egress_allow[]` is the init
message's `xl.egressAllow` (or the `PDSH_EGRESS_ALLOW` environment entry). `publishCapabilityManifest()` compares a SHA-256
content hash and writes only changed content, so a Worker restart over
unchanged home emits no `VFS_MUT`. The image build additionally asserts the
`agent-instructions` row is in the roster and enabled, because a profile change
that drops it would leave the files unread.

## Python-on-WASI wiring

W7 ships `PythonRuntime` as a library, so the Worker entry is its production
caller. After the namespace install and before `pdsh-ready` the entry:

1. reads `/dsh/bin/python/python.wasm` and `/dsh/bin/python/python313.zip` from
   the mounted image (the packer's `--python <build.sh output>` staging);
2. builds `PythonRuntime` with the namespace's identity preopens
   (`/dsh/workspace`, `/dsh/home`, `/tmp`, `/dsh/tmp`) backed by the same VFS —
   the namespace the shell uses, with `cwd`/`PWD` handed through unchanged — and a
   `NodeFsBackend` over the host VFS's own `promises` face (falling back to the
   `node:fs/promises` proxy only for a host that exposes no promise face), so a
   Python write is an ordinary DSH write, `os.getcwd()` is the shell's
   directory, and the binding follows the host that published it rather than
   module-global state;
3. verifies that the toolbox's file view resolves the shell's persisted roots
   (`assertFileView`, with the `snapshotFallback` the WASI toolbox uses when a
   rebuilt Worker has no `SharedArrayBuffer` channel) and fails loud before
   publishing if it cannot, instead of serving `python3` an empty `/`;
4. calls `installShellDispatch()`, which publishes the toolbox
   (`setWorkerToolbox()`); `createWorkerCommands()` then registers `python3`
   for both `bash -c 'python3 ...'` and a direct `spawn(['python3', ...])`.
   The published runtime also serves Python's `subprocess` family: the tool
   worker mounts the read-only `subprocess` shim (`python/subprocess-shim.ts`)
   and intercepts `/__xl__/spawn`, so a `Popen` runs a fresh interpreter
   instance on the same module, preopen table and VFS as the shell dispatch
   (see `wasi-toolbox/python/README.md`). The boot path needs no extra option:
   the bridge is part of `PythonRuntime`'s toolbox.

Every boot path — cold boot and the rebuild paths (`park`/`resume`,
`planned_restart`, Worker kill, WebContent kill) — binds through one
`PythonToolboxLifecycle`: binding to a different host VFS disposes the previous
wiring first, so the published `python3` is always the one bound to the live
host. A test can boot the entry twice in one global scope and once in a fresh
process (`plugins/tests/python-toolbox-rebuild.test.ts`).

An image with no python artifacts logs one visible line and keeps booting. An
image that has one artifact (or empty bytes) fails loud with `pdsh-error` and the
`build.sh` command to run, instead of letting every Python step exit 127 later.
`stop()` disposes the runtime and unpublishes the toolbox.

## D22: ordered-channel authentication marker

DSH's loopback surface authenticates browser requests with an HttpOnly cookie
exchanged from the launch token. A request that arrives over the ordered
channel has already been authenticated by the host app's channel bearer; no
cookie is exchanged over the channel.

The Worker entry therefore marks every request it forwards from the ordered
channel with:

```
x-pdsh-channel-authenticated: 1
```

Rules:

- only `src/entry.ts` sets the header;
- an inbound `x-pdsh-channel-authenticated` header of any case is removed before
  the request is synthesized for the DSH webserver (a model or caller cannot
  spoof it);
- the synthesized `host` header is always `127.0.0.1`, matching the loopback
  trust fence;
- `plugins/surface-phone` treats the marker as authenticated and keeps the
  cookie exchange for the browser page path.

The behavior is implemented by `withChannelAuthentication` and applied in
`serveApiRequests`; `src/mux-bridge.test.ts` asserts the inbound copy is
stripped and exactly one entry-owned marker reaches the listener.

## D23: `/api/remote.mux` bridge

The SDK's `ChannelDSHTransport` represents DSH's `/api/remote.mux` WebSocket as
unary channel API requests:

```
POST /api/remote.mux
x-pdsh-mux-id: <32 lowercase hex>
x-pdsh-mux-op: send | receive | close
content-type: application/json       (send, close)
content-type: application/x-ndjson   (receive)
```

Semantics implemented by `WorkerEntryMuxBridge`:

- one logical mux session per `x-pdsh-mux-id`, opened on the first `send` or
  `receive`;
- `send` carries exactly one canonical JSON mux frame (`open`, `item`, `end`
  or `cancel`, the DSH stream-protocol client messages) and answers 2xx;
- `receive` is a long-lived response of newline-delimited canonical JSON mux
  server frames (`item`, `end`, `error`). Frames are emitted in order, one
  line per frame, flushed immediately; a line larger than 4 MiB is split
  across API_RES chunks, none larger than the 4 MiB API body limit;
- frames produced while no receive is attached are queued and flushed to the
  next receive, so a send that makes the server answer before the host opens
  its receive loses nothing;
- `close` closes the logical session: open streams are cancelled, queued
  frames are flushed, and the receive response ends;
- a lost channel and worker disposal cancel every open stream and drop every
  session; an aborted receive only detaches that response, so the host can
  reopen a receive with the session's streams still running;
- an unknown operation or a malformed mux id answers `400` with
  `x-pdsh-proxy-error: mux_invalid_id` / `mux_invalid_operation` and a canonical
  JSON body `{"error":{"code","message"}}`. A malformed `send` body answers
  `400` with `mux_invalid_frame`, and a receive for a session that already has
  one answers `409` with `mux_receive_in_flight`.

### How the session is driven in-process

The `/api/remote.mux` route is an HTTP upgrade route. The pinned Worker runtime
deliberately makes `ws` a not-implemented proxy (the fake HTTP server never
emits `upgrade`), so the bridge cannot fabricate a socket. Instead,
`src/mux-tunnel.ts` drives the runtime's own in-process stream lane: the tunnel
frames `stream-open`, `stream-uplink-item`, `stream-uplink-end` and `abort`
reach `typertGateway.wireStream.open`, which is the same handler the gateway's
`RemoteStreamMuxServer` calls after it decodes a WebSocket frame. The entry
supplies the runtime host with a tunnel port it also observes, so outbound
`stream-item` / `stream-end` / `stream-error` frames become mux server frames.

Tunnel stream ids are namespaced (`pdsh-mux:<mux-id>:<generation>:<stream-id>`) so
concurrent mux sessions, a reopened mux id, and the page's own tunnel traffic
cannot collide. No DSH source is copied or patched.

WebKit/on-device behaviour of this bridge remains `NOT_VERIFIED`; the unit
tests run under Node with the in-memory channel and a fake mux server.

## Tests and checks

```sh
cd plugins
npm run typecheck
npm test
```

`npm test` runs `src/entry.test.ts`, `src/web-boot.test.ts`,
`src/jsc-compat.test.ts`, `src/profile-overlay.test.ts`,
`src/bounded-opendir.test.ts` and the workspace suites, including
`tests/sharp-shim.test.ts` (image decode regression),
`tests/worker-command-bounded-opendir.test.ts` (real pinned MemoryVfs and
runtime-fs integration) and the pack-image seam tests. The mux suite
covers a send/receive round trip, two interleaved mux ids, receive end on close,
4 MiB chunking, canonical JSON, inbound marker stripping, the 400 error
contract, the tunnel lane mapping and channel-loss cleanup. The prelude suite
covers installation, idempotency, untouched native definitions, the stubbed
source entry and the built bundle; the entry suite also covers binary stdout not
hiding `XL_DSH_READY`.
