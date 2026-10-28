# @phone-dsh/dsh-wasi-toolbox

The WASI toolbox that runs inside the DSH phone Web Worker. It hosts a WASI
preview1 runtime in a dedicated tool worker, proxies the DSH in-memory
filesystem to that worker, compiles each wasm module once and keeps one warm
instance per tool. Command routing is exposed as a table: publishing it with
`setWorkerToolbox()` makes `@phone-dsh/dsh-shell-ext` register one shell
command per program (`python3`, later WASI tools), so commands stay in the
Worker instead of going to the host. The package also carries the JavaScript
`git` program (`./git`) for the same shell table.

No runtime dependency is added: the WASI preview1 host is our own
implementation, not a vendored or patched third-party shim.

## Processes and channels

```
DSH Web Worker                              dedicated tool Worker
┌──────────────────────────────┐            ┌──────────────────────────────┐
│ WasiToolbox (command table)  │  init      │ HotInstance                  │
│  ModuleCache ── Module ──────┼───────────▶│  WebAssembly.Module (clone)  │
│  VfsProxyServer              │  exec      │  WasiPreview1 (preview1 ABI) │
│    NodeFsBackend = node:fs   │◀──────────▶│  SyncVfsClient / ProxyWasiVfs│
│      (sink sees every write) │  SAB       │                              │
└──────────────────────────────┘            └──────────────────────────────┘
```

- **Module cache** (`module-cache.ts`): one `WebAssembly.compile` per module
  URL; `WebAssembly.Module` is structured-cloneable, so the compiled module is
  posted to each tool worker in its `init` message. Two programs with the same
  URL compile once.
- **Hot instance** (`hot-instance.ts`): the compiled module and the worker stay
  warm between commands. Every `run()` gets a fresh `WebAssembly.Instance` and a
  fresh WASI fd table/env, because a wasm instance cannot be reused after
  `_start` without inheriting the previous command's heap and libc state.
  `reset()` drops the instance; `terminate()` is used only for cancellation.
- **Memory ceiling**: `DEFAULT_HOT_INSTANCE_MEMORY_BYTES` is 150 MB (PLAN §2.5,
  8 GiB tier; the table in `limits.ts` has the 6/4/3 GiB tiers). Defining
  modules are checked on every host call; imported memories get a real
  `maximum`. A ceiling hit exits 137 and the warm worker serves the next command.
- **Worker URL**: `WasiToolbox` spawns the built tool worker (`workerUrl`,
  default `./tool-worker.js` next to the bundle) and posts the compiled module
  in `init`. A host that bundles the worker itself passes `workerUrl` or a
  `spawnWorker` factory.
- **Command table** (`toolbox.ts`): `has()`/`get()`/`list()` for routing,
  `run({program, argv, env, cwd, stdin, signal, onStdout, onStderr})` for
  execution. Unknown programs answer 127 like a shell. Optional
  `maxStdoutBytes`/`maxStderrBytes` cap each captured stream; crossing one
  stops the guest through the normal terminate path and resolves
  `E_OUTPUT_LIMIT` with the produced/kept byte counts and a truncation flag
  rather than letting an infinite writer grow the Worker heap.
- **stdin delivery** (`stdin-delivery.ts`): `stdin` is a complete byte stream
  delivered as an explicit dispatch step — bounded 1 MiB frames followed by an
  EOF marker, then the `exec` that names the byte count. The tool worker
  assembles the frames, reports the assembled byte count, and refuses a
  truncated delivery (`E_STDIN_INCOMPLETE`) rather than reading it as an empty
  script; a count that disagrees with the dispatch is the same failure. The
  dispatch watchdog fails the command fast with `E_EXEC_START_TIMEOUT` when the
  tool worker never
  acknowledges the exec, and with `E_STDIN_READ_TIMEOUT` when a command that
  declares `scriptFromStdin` (`python3 -`) starts but never performs its first
  `fd_read(0)`. Without those bounds a wedged interpreter held the Worker
  execution lane until the shell's 120 s wall clock. The bounds are constructor
  options and, for a field diagnosis, environment knobs symmetric with the
  shell's `PDSH_SHELL_STDIN_TIMEOUT_MS`:
  `PDSH_TOOLBOX_EXEC_START_TIMEOUT_MS` (default 10000) and
  `PDSH_TOOLBOX_STDIN_READ_TIMEOUT_MS` (default 20000).
- **Read-only stdlib layer** (`readonly-vfs.ts`): `ReadOnlyMemoryVfs` holds a
  packed tree (the CPython stdlib package consumes it) and `OverlayWasiVfs`
  mounts read-only layers in front of the writable proxy. Reads and `readdir`
  merge, and every mutation under a layer root answers `EROFS` instead of
  silently shadowing the read-only tree.
- **Subprocess bridge** (`spawn-bridge.ts` + `wasi-preview1.ts`): preview1 has
  no process model, so the host serves one private control file at
  `/__xl__/spawn`. A guest writes one framed request (argv, env, cwd, binary
  stdin) and reads one framed response (exit code, binary stdout/stderr); the
  host runs a fresh interpreter instance in the same tool worker, module and
  `WasiVfs` (`hot-instance.ts`), so a nested command's file I/O is an ordinary
  DSH write on the one proxy/durability chain. Only the interpreter can be
  nested; any other program is a loud error. The Python side is
  `python/subprocess-shim.ts` (`python/README.md`); the descriptor is
  intercepted before any VFS call, and everything else under the private root
  answers `ENOENT`/`EROFS`.
- **HTTP egress bridge** (`http-bridge.ts` + `wasi-preview1.ts`): the same
  private root also serves `/__xl__/http`. A synchronous guest writes
  `u32 header_len | u32 body_len | JSON {op:"request", method, url, headers} |
  body` and reads `u32 header_len | JSON {status, reason, headers, bodyBytes} |
  body`, with `{error:{kind,message}}` for every failure. The Python tool
  worker builds the transport from the loopback `/v1/http` route the DSH Worker
  injected and uses one synchronous `XMLHttpRequest`; the channel bearer never
  enters the guest environment or VFS. Limits are 1 MiB of header, 16 MiB of
  request body and 64 MiB of response body, and an over-limit frame fails
  structurally. The Python side is `python/http-shim.ts`; the descriptor is
  available only when a route exists, so a host without one keeps the original
  "unknown url type: https". The redirect boundary is the host, not a
  transport post-check: `HTTPResponseWriter` strips `Location` from every
  residual `3xx` egress response on `/v1/http` (case-insensitive, status and
  body preserved), so the synchronous XHR has no target it could auto-follow
  to another loopback control route. Redirects that the host egress policy
  itself permits and follows remain host operations. A residual `3xx` with no
  `Location` reaches Python as a non-success status and `urllib` raises
  `HTTPError`; automatic redirects through this bridge are explicitly
  unsupported. See the plugin tests and
  the plugin tests.

## jq engine

The package also hosts the jq-compatible WASI executable built from the
repository's `pdsh-jaq-wasm` crate (`crates/pdsh-jaq-wasm` in the `shell/`
workspace) over the MIT jaq-core/jaq-std/jaq-json libraries. It is a real
filter engine, not a token rewrite: `input`/`inputs` consume one shared lazy
stream, `input_line_number` follows jq 1.6's `fgets` accounting, and
`$ARGS`/`$__loc__`/`reduce`/`foreach`/`break` are the language's own
semantics. Files are read through the same preopened Worker VFS, stdout/stderr
are real WASI fds, and cancellation/memory limits are the existing hot-instance
path.

The image stages exactly `bin/jq/jq.wasm` and its `engine.json` build report;
`worker-entry/src/jq-toolbox.ts` registers it as `jq-wasi` (alias `jaq`) on the
published toolbox, and `createJqCommand()` in shell-ext routes the `jq`
command to it when present. An image without the artifact keeps the old
fail-loud shim; the capability manifest only advertises the engine when the
wiring actually exists. Build products are never committed:

```sh
bash plugins/wasi-toolbox/jq/build.sh --out <dir>   # jq.wasm + engine.json + sizes.json
bash scripts/ci/jq-artifacts.sh                     # default cache helper
```

See the plugin tests for the native jq 1.6 comparison and the
documented jaq deviations.

## Path authority (VfsNamespace)

One module, `vfs-namespace.ts`, owns "which virtual path, which backend and
which policy" for every execution surface. The table is fixed by
`spec/v1/channel.md` §6:

| root | kind | sink | budget bucket |
|---|---|---|---|
| `/dsh/workspace` | durable | yes | `workspace` |
| `/dsh/home` | durable | yes | `sessions` |
| `/tmp` | volatile | no | `tmp` |
| `/dsh/tmp` | volatile | no | `tmp` |
| `/dev/null` | device | no | `none` |

- `resolve()` folds dot segments and translates the legacy runtime spellings
  `/workspace` and `/home`. `/tmp` is a root, not a translation.
- `storagePath()` canonicalises `/tmp/**` onto `/dsh/tmp/**`. That is the one
  mapping that makes the write tool, `bash`, `python3` and `git` see one file
  for one name; the shell adapter's own `/tmp` bridge becomes idempotent.
- `classify()`/`sinkEligible()` answer the D4 question (a `.git` component is a
  normal component; a volatile or image path is never sent).
- `execReadable()`/`assertExecReadable()` deny `/dsh/home/sessions`,
  `/dsh/home/storages` and `/dsh/home/tool-journal` to `bash`, `python3` and
  `git` with `EACCES` and one remediation line. The runtime's own services keep
  reading them. A WASI errno cannot carry text, so the WASI host also writes
  the line to the command's stderr (the same mechanism the `EFBIG` refusal
  uses).
- `join(base, pattern)` is the single base+relative-pattern join for search
  surfaces (glob, grep), preserving a leading `!`.
- `preopens()` is the identity preopen table generated from the roots;
  `createNamespaceVfs()` wraps the mounted VFS so every `node:fs` caller sees
  the canonical storage path; `wrapFsPromises()`/`installExecFsPolicy()` give a
  `node:fs/promises`-shaped face the same resolution and read policy.

The Worker entry (`worker-entry/src/namespace-boot.ts`) installs the authority
right after `host.start()`, seeds the volatile roots and probes both spellings;
a divergence is a loud boot failure. The root table and sink predicate are
therefore not duplicated per adapter.

## VFS proxy

The tool worker has no filesystem. Preopened guest directories are resolved to
host paths before they leave the guest; the server re-checks that every host
path is inside a preopen root, so `..` cannot escape. The default table is the
namespace's identity roots — `/dsh/workspace`, `/dsh/home`, `/tmp` and
`/dsh/tmp` — so a WASI program sees the same tree under the same names as
`bash -c` (`ls`, `cat`, `awk`, ...). `/tmp` is one of those roots; the
namespace, not a second mount, makes it the same storage as `/dsh/tmp`. Every
guest path is canonicalised and checked against the exec read policy before the
backend sees it. Requests are whole-envelope frames (JSON + binary,
`vfs-protocol.ts`), which gives two transports:

- **Async** (`AsyncVfsClient`): request/response frames over `postMessage`,
  batched so one call can carry several `stat`/`readdir`/`read`/`write`
  operations. The tool worker uses it for the preopen probe at init.
- **Sync** (`SyncVfsClient`): the same frame is copied into a `SharedArrayBuffer`
  request region, the guest `Atomics.wait`s, the DSH worker serves it on its
  event loop and `Atomics.notify`s the response region. This is the only way a
  synchronous WASI `fd_read`/`path_open` can block on another thread, so it is
  selected automatically when `crossOriginIsolated` is true and
  `SharedArrayBuffer` exists.

Without COOP/COEP (`crossOriginIsolated === false`) the async channel still
works for the control plane, but WASI file syscalls have no synchronous
transport. A toolbox that opts into `snapshotFallback` (the python wiring does)
then captures the preopened trees over the async channel and serves them from a
local `SnapshotWasiVfs`: reads are synchronous from the snapshot, mutations are
applied locally and written back through the async proxy before the command's
exit is reported. A truncated capture or a missed required root fails loud
instead of serving a partial view. Toolboxes without the option keep the
`ENOTCAPABLE` answer — the toolbox never fakes file I/O.

The snapshot is **recaptured from the live VFS before every dispatch** when
`refreshSnapshotOnRun` is on (the default whenever `snapshotFallback` is on),
so a `bash` step that created, changed or removed a file after the previous
WASI command is visible to the next one: the shell and `python3` agree on
everything a completed step committed. The read view is still a point-in-time
capture, not a live mirror: a file written *while* a WASI command is running is
seen by that command's later reads only when it wrote the file itself, and is
visible to the next command. Write-behind means a guest write is only durable
for other steps after the tool worker flush completes (reported in the command's
exit), and a failed flush turns the command's exit non-zero. A capture that
truncates (48 MiB / 8192 entries) or misses a required root fails loud rather
than serving a partial tree. Recapturing also means the host does not pin a
boot-time copy of the workspace: memory is transient per dispatch.

iOS WebKit's `crossOriginIsolated` behaviour on the phone host is
**NOT_VERIFIED** in this package; the W3 probes own that measurement. A Worker
rebuilt by a recovery path is the concrete case: `python3` must keep the same
file view as `bash` on every (re)construction (G2-FIX-54).

Writes reach `NodeFsBackend`, which wraps the host VFS's own `promises` face
(`MemoryVfs.promises`, pinned to the filesystem object the host mounted) or,
for a host that exposes only the structural VFS, the `node:fs/promises` proxy of
the DSH worker's runtime filesystem. In the packed image that is the in-memory
authority whose mutation sink feeds the WAL, so a WASI write is a normal DSH
write and the sink sees it. Unit tests use the in-memory
`MemoryVfsBackend` instead.

The command boundary is a durability fence (G2-FIX-61). A guest `write` only
updates the Worker VFS; the sink appends to the host WAL asynchronously and the
level-1 ack arrives later. Before `WasiToolbox.run()` resolves a dispatch it
calls the backend's `sync()` — `NodeFsBackend.sync` is
`host.vfs.flush()` — so a successful `python3` has every mutation of the command
in the host WAL and materialized copy. Without that fence a WebContent kill
right after a successful command dropped the last in-flight mutations from the
Worker VFS, the WAL and the materialized copy (the G2-F07 60-frame directory).
A backend without `sync` (the in-memory test backend) has nothing to fence.

## Write outcomes (G2-FIX-103)

The command-boundary fence alone is not enough for the *individual* write: a
guest `fd_write` used to return as soon as the Worker memory VFS accepted the
bytes, so the host's answer arrived later and had nowhere to go. A host
resource refusal (`ERROR VFS_REFUSED`, channel.md §4.8) was invisible to the
interpreter, and a D3 flow-control stall (32 MiB of unacknowledged frames, no
`0x11`) had no bound on that surface: G2-A09 (attempt 7) sat inside `fd_write`
while the host had already applied everything the Worker published.

`NodeFsBackend` now takes an optional `writeOutcomes` tracker
(`write-outcomes.ts`). The sink and the backend share one instance per Worker
boot:

- around every `writeFile`/`truncate` the backend opens a ticket, the sink
  attaches each `VFS_MUT` it publishes for that path, and the backend awaits the
  ticket before the proxy answers the guest;
- a level-1 (or level-2) `VFS_ACK` covering every attached `mseq` resolves it;
- a host refusal rejects it with the same `EFBIG`/`ENOSPC`/`EDQUOT` errno the
  Worker pre-check raises. The message carries the exact limit in bytes (plus
  the MiB spelling) and a split/chunk remediation, the refusal consumes no
  `mseq`, and the channel stays open; the WASI host returns the errno to the
  interpreter and mirrors the line on stderr;
- one refusal can reach the tracker twice: the sink's frame listener sees the
  `ERROR` and a command-boundary `flush()` parked on the same `mseq` catches it
  from its rejected `waitAck`. Delivery is idempotent per `(mseq, path)` in the
  current numbering, so the duplicate neither renumbers the surviving in-flight
  writes a second time nor rejects the write that moved into the freed slot; a
  later genuine refusal of the write the channel renumbered into that slot
  carries its own path and settles it instead of being dropped as that
  duplicate;
- no ack within the configured bound (D3's 30 s, validated by
  `resolveVfsFlowControlTimeoutMs` / `PDSH_VFS_FLOW_CONTROL_TIMEOUT_MS`) rejects
  with the typed `VfsFlowControlError`, leaves the channel untouched, and lets
  the command settle as a tool result. A later ack that covers the pending
  range clears the failure;
- a structurally failed or closed sink rejects every pending ticket, so no
  write can stay parked.

A mutation that never reaches the sink (a volatile root, or a local pre-check
refusal) has no host outcome and settles immediately, so `/tmp` writes and the
existing `EFBIG` pre-check keep their fast path. The in-memory
`MemoryVfsBackend` has no sink and no tracker; it stays a test double.

Both backends enforce the configured single-file budget (`MAX_FILE_SIZE`, 64 MiB
by default; the host's `PDSH_SINGLE_FILE_LIMIT_BYTES` is clamped to 16–128 MiB and
applied by `configureSingleFileLimit`) before they touch the runtime filesystem:
a whole write, an append whose post-write file would exceed it, or a `truncate`
that would grow the file past it fails with `EFBIG: File too large: <path>
would be <n> bytes; a file is limited to <bytes> (<n> MiB)`. Both numbers are
rendered from the same configured value by `formatByteLimit` (the budget owner
in `limits.ts`), so the label can never name a different tier than the check
enforced — the G2-FIX-100 defect where a 64 MiB refusal still said `(15 MiB)`.
This is the surface `python3` uses, so an over-limit Python write is the
command's own error and the ordered channel stays open. A WASI errno cannot
carry text, so the WASI host mirrors an `EFBIG` refusal on the command's
stderr; `python3` still reports its own `OSError: [Errno 27] File too large`
and exits non-zero.

## Job settlement (G2-FIX-104)

A WASI dispatch runs inside a tool worker, but the job that owns it lives in
`subprocess-xl`. The interpreter can block in a proxied syscall (`fd_write`
waiting on a sink, an `Atomics.wait` on a stalled host) and never return, while
the per-workspace execution lane stays held. A deadline or drain settlement that
waits for `run()` therefore waits behind the very dispatch it has to stop —
G2-A09: `timeoutMs: 120000` expired, the runner's 20 s drain elapsed, no
`tool/result`, journal end or D13 step ever followed.

The toolbox exposes an external, synchronous stop face:

- `WasiToolbox.terminate(cause)` (`cause`: `timeout` | `drain` | `cancel`)
  drops every warm worker, resolves each active `run()` synchronously with a
  terminal result (`E_JOB_TIMEOUT` exit 124, or `E_JOB_DRAIN`/`E_JOB_CANCEL`
  exit 130), asks the transport to terminate **without awaiting it**, and
  returns the number of dispatches it stopped. A dispatch that is queued behind
  the wedged one observes its own abort instead of waiting for the queue.
- Every path the active dispatch mutated through the VFS proxy is recorded.
  On a hard stop the toolbox writes a `*.pdsh-partial` marker beside it
  (`{v:1, kind:"pdsh-partial-write", program, path, cause, at_ms}`); if the
  marker write is refused, the half-written file is removed instead. The
  materialized workspace therefore never carries an unmarked partial file. A
  later successful write of the same path removes the stale marker.
- `partialWritesSettled()` resolves when the marker writes started by a stop
  have finished; `dispose()` awaits it.
- A `0x50 LIFECYCLE stop` delivered through the Worker entry's
  `pdsh-lifecycle` event also hard-stops the active dispatch, so a drain that
  never reached the subprocess layer still cannot park an interpreter.

`subprocess-xl` calls this through the `__PDSH_WASI_TOOLBOX__` Worker global from
its job-registry terminator (no package dependency edge, the same convention as
`__PDSH_VFS_FLUSH__`), so the settlement timer and the drain fan-out live outside
the execution-mutex domain.

## Wiring it

```ts
// import { NodeFsBackend, WasiToolbox } from '@phone-dsh/dsh-wasi-toolbox'
// (the package is registered in plugins workspaces, so the name resolves)

const toolbox = new WasiToolbox({
  // The DSH worker's node:fs face; its sink is what mirrors writes to the WAL.
  backend: new NodeFsBackend(dshNodeFsPromises, { flush: () => host.vfs.flush() }),
  preopens: [
    { guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' },
    { guestPath: '/dsh/home', hostPath: '/dsh/home' },
    { guestPath: '/dsh/tmp', hostPath: '/dsh/tmp' },
  ],
  commands: [{
    program: 'python3',
    module: { url: 'image://python.wasm', load: () => readImageFile('python.wasm') },
  }],
})

// Publish the toolbox for the Worker shell: createWorkerCommands() in
// @phone-dsh/dsh-shell-ext then registers one command per program, so
// `bash -c 'python3 …'` and a direct spawn(['python3', …]) both reach
// toolbox.run() with no second code path.
setWorkerToolbox(toolbox)
```

`crossOriginIsolated` is detected from the worker global; a host can override it
for tests. The packer ships the built `tool-worker.js` next to the toolbox
bundle, or the host passes `workerUrl`/`spawnWorker`. The package also exports
`./git` (the Worker git program), `./python` (`PythonRuntime`, see
`python/README.md`) and `./tool-worker-python` (its worker entry); the image
stages those faces as `lib/git.js`, `lib/python.js` and
`lib/tool-worker-python.js`.

## WASI preview1 coverage

`wasi-preview1.ts` implements the preview1 imports needed by the toolbox:
args/environ, clocks, `random_get`, `proc_exit`, `fd_read`/`fd_write`/
`fd_pread`/`fd_pwrite`/`fd_seek`/`fd_tell`/`fd_close`/`fd_fdstat_*`/
`fd_filestat_*`/`fd_readdir`/`fd_prestat_*`/`fd_renumber`/`fd_sync`,
`path_open`/`path_filestat_get`/`path_create_directory`/
`path_remove_directory`/`path_unlink_file`/`path_rename`, `poll_oneoff`
(clocks), `sched_yield` and `sock_*` stubs that answer `ENOSYS`.
`path_filestat_set_times` and symlink operations answer `ENOSYS`/`ENOTSUP`
rather than pretending to succeed.

## Fixture

`src/testdata/fd-echo.wasm` is checked in with its WAT source and exercises
`path_open`, `fd_read` and `fd_write` end to end through the SAB proxy. It was
assembled with wabt (Apache-2.0) at authoring time; wabt is not a dependency.
See `src/testdata/README.md`.

## Tests

`npm test` from `plugins` runs `node --test "wasi-toolbox/**/*.test.ts"`, which covers:

| File | Coverage |
|---|---|
| `vfs-proxy.test.ts` | stat/read/write/append/truncate/open/readdir/mkdir/rename/unlink, batched frames, capability rejection |
| `vfs-sab.test.ts` | blocking `Atomics.wait` client in a second thread |
| `module-cache.test.ts` | one compile per URL, retry, structured-clone sharing |
| `hot-instance.test.ts` | fd_read/fd_write/path_open, reset, trap, memory ceiling |
| `toolbox.test.ts` | real tool workers, streaming, module sharing, cancel, ceiling, no-COI path, routing |
| `stdin-delivery.test.ts` | bounded stdin frames, explicit EOF, truncated/out-of-order delivery, feed EOF |
| `readonly-vfs.test.ts` | stdlib layer reads, merged readdir, `EROFS` mutations, writable tree unaffected |
| `../tests/wasi-python-subprocess.test.ts` | subprocess bridge protocol, nested interpreter on the real CPython artifact: capture_output, stdin, exit codes, VFS chain, snapshot fallback, loud unknown program |
| `../tests/wasi-write-outcome.test.ts` | G2-FIX-103: a real `python3` guest over a scripted host channel — a `VFS_REFUSED` becomes the write's EFBIG errno with the limit and remediation, a withheld `VFS_ACK` fails the write with the bounded typed error, the channel stays open and the command settles |
| `write-outcomes.test.ts` | outcome tracker contract: cumulative acks, refusal-to-errno, mseq renumbering, bounded flow-control failure, volatile writes, disposal |
| `../tests/wasi-job-settlement.test.ts` | G2-FIX-104: a WASI dispatch blocked in a proxied syscall is hard-stopped at `timeoutMs` and on a host drain, emits a terminal tool result and journal end, marks/cleans its partial write and releases the execution lane |
