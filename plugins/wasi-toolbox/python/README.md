# CPython 3.13 on wasm32-wasi — spike and go/no-go

**Decision: GO for `python3` in the WASI toolbox**, conditional on the W3
`crossOriginIsolated` / `SharedArrayBuffer` probe passing on the phone host
(the filesystem channel already requires it; the interpreter itself does not).
The spike ran CPython 3.13.17, built from source with WASI SDK 25.0, through
the W7 runtime on an Apple Silicon Mac. Nothing here has run in iOS WebKit yet:
every phone-specific statement is **NOT_VERIFIED**.

The licence decision is fixed by the research: this is CPython's own
`wasm32-wasi` port (PSF-2.0, PEP 11 tier 2),
not Pyodide (MPL-2.0). Pyodide is mentioned only to record that it is not used:
its build glue is MPL-2.0 and is outside this repository's dependency policy.

## Artifacts

| File | What it is |
| --- | --- |
| `build.sh` | pinned, reproducible build (`--check` probes the default artifact and rebuilds it when missing or stale; an explicit `--out` is only verified) |
| `lockfile.json` | CPython, WASI SDK and compression-library versions, URLs and sha256 digests |
| `compression-probe.ts` | the probe programs and validators used by the build and the tests |
| `verify-compression.mjs` | runs the probe against a produced `python.wasm` (`build.sh` gates on it) |
| `python-artifacts.ts` | selects the pair the compression tests execute: trusted explicit paths, or the default build after its `sizes.json`/`compression.json` reports and capability probe pass |
| `runtime.ts` | `PythonRuntime`: mounts the stdlib in worker memory, registers `python3` in the W7 toolbox, measures the benchmark |
| `python-worker-runtime.ts` | the dedicated tool worker: `OverlayWasiVfs` over the stdlib layer plus the synchronous DSH proxy |
| `tool-worker-python.ts` | worker entry the DSH worker spawns |
| `testdata/stub-python.wasm` | tiny WASI stdio stand-in used when no real build exists |

Build products are never committed. `build.sh` defaults to
`$TMPDIR/pdsh-python-wasi` and refuses an `--out` directory inside the
repository. A build writes `python.wasm`, `python313.zip`, `compression.json`
and `sizes.json`.

## Build

```sh
bash plugins/wasi-toolbox/python/build.sh --check
bash plugins/wasi-toolbox/python/build.sh --out "$TMPDIR/pdsh-python-wasi" --jobs 8
```

The inputs come from pinned public release locations:

* CPython 3.13.17 source tarball from `python.org` (sha256 in `lockfile.json`).
  That is CPython's official source-release location; GitHub's auto-generated
  tag archives are not stable, checksummable artifacts.
* WASI SDK 25.0 macOS release from the `WebAssembly/wasi-sdk` GitHub release
  (sha256 per host architecture in `lockfile.json`).
* zlib 1.3.1 and liblzma 5.6.4 from their maintainers' GitHub release assets,
  and bzip2 1.0.8 from the CPython project's `cpython-source-deps` source
  mirror that CPython's own Windows build consumes, each with a sha256 in
  `lockfile.json`. bzip2 has no GitHub release of its own, so its tag archive
  is pinned by sha256; if GitHub ever regenerates it differently, the download
  check fails loudly instead of building unknown bytes. Only `liblzma` is
  built from the XZ Utils tarball; the xz command line tools and scripts are
  disabled, so the shipped code is 0BSD.

Before the interpreter is configured, `build.sh` cross-builds zlib, bzip2 and
liblzma as wasm32-wasi static libraries with the same WASI SDK. It then follows
CPython's `Tools/wasm` recipe: a native build Python is produced first, then
`Tools/wasm/wasi-env` cross-compiles with `--host=wasm32-unknown-wasi`,
`CPPFLAGS=-I<deps>/include` and `LDFLAGS=-L<deps>/lib` so `configure` finds the
compression headers and archives. After configure, the generated
`Modules/Setup.stdlib` must list `zlib`, `_bz2` and `_lzma`; if a library was
not detected the build stops instead of producing a Python without compression.
The extension modules are linked statically into `python.wasm` (this build has
no dynamic module loading), so the packed pair carries them. `--wasi-sdk`,
`--source`, `--source-archive` and `--sdk-archive` allow reuse of an already
downloaded SDK or source tree, which
is also how a machine behind a mirror builds. CPython 3.13.17's own
`Tools/wasm/build_wasi.sh` is not invoked directly: it hard-codes
`#!/usr/bin/bash` and `./python`, while the macOS out-of-tree build produces
`python.exe`; `build.sh` runs the same configure/make steps with those two
assumptions removed.

The standard library zip is written with `ZIP_STORED` entries: `zipimport`
then serves every module without paying deflate at import time, and the stable
entry layout keeps the read-only mount simple. The packing step asserts that
`tarfile.py`, `gzip.py`, `bz2.py`, `lzma.py` and the `zipfile` package are
present.
`test`, `tests`, `idlelib`, `ensurepip`, `lib2to3`, `tkinter` and `turtledemo`
are excluded; `ensurepip` is what makes `pip` unavailable by construction.

`verify-compression.mjs` runs the produced interpreter under Node's WASI host
with the stdlib zip mounted read-only and a writable `/tmp`. It requires
`import zlib, bz2, lzma`, a `zlib`/`bz2`/`lzma` compress/decompress roundtrip
of a 1344-byte payload, a `tarfile.open(name, "w:gz")` write/read roundtrip,
and then gunzips the archive the guest wrote with Node's own `zlib` to inspect
the bytes independently. `build.sh` writes `compression.json` only after that
probe passes, and `--check` runs the same probe against an existing artifact.
The spec gate is `build.sh --check && npm test`, and artifacts are never
committed, so `--check` treats the *default* output directory as managed state:
when the pair is missing, incomplete, lacks the verified reports, or predates
the compression build, it rebuilds that directory from the pinned sources and
probes the new pair before exiting 0. A stale pre-fix `python.wasm` therefore
cannot make the gate green, and it also cannot leave the gate permanently red:
it is replaced with a verified interpreter. An explicit `--check --out DIR` is
caller-owned, so it only verifies that directory and fails loudly when the pair
is stale (this is what release callers should run before staging an existing
artifact). If a build cannot provide zlib/_bz2/_lzma, `--check` still fails
loudly in both modes.

### Measured artifact sizes

Measured in this worktree (CPython 3.13.17, WASI SDK 25.0, zlib 1.3.1,
bzip2 1.0.8 and liblzma 5.6.4 linked in, macOS arm64):

| Artifact | Bytes |
| --- | --- |
| `python.wasm` | 30,273,026 (28.9 MiB) |
| `python313.zip` (stored) | 10,345,856 (9.9 MiB) |
| total | 40,618,882 (38.7 MiB) |

`build.sh` writes the same numbers with sha256 digests to `sizes.json`, plus the
compression probe report (zlib 1.3.1, `bz2`/`lzma` roundtrips, `tarfile w:gz`)
to `compression.json`. A rebuild can differ between runs (embedded build paths
and zip metadata), so the `sizes.json` written beside an artifact is the
authoritative record for that pair; the table above is this worktree's last
measured build.

**The artifacts are not in the repository, but they do go into the packed
Worker image.** `scripts/pack-image.mjs` resolves them from `--python <dir>`
(the `build.sh` output directory) or from `PDSH_PYTHON_WASM`/`PDSH_PYTHON_STDLIB`,
copies exactly the pair into the image at `bin/python/`, and records both sizes
in `sizes.json`. The Worker sees them at:

| Image path | VFS path |
| --- | --- |
| `bin/python/python.wasm` | `/dsh/bin/python/python.wasm` |
| `bin/python/python313.zip` | `/dsh/bin/python/python313.zip` |

The mount sits under `bin/` like the runtime's `/dsh/bin/rg`; the constants are
`PYTHON_IMAGE_MOUNT` in `scripts/pack-image.mjs` and `PYTHON_IMAGE_DIRECTORY` in
`worker-entry/src/python-toolbox.ts`. Asking for python while a file is missing
fails the image build with the exact `build.sh` command; an image that carries
neither file simply has no `python3`.

At Worker boot `worker-entry/src/python-toolbox.ts` reads both paths from the
mounted VFS, builds `PythonRuntime` with the preopens below, and publishes the
toolbox before `pdsh-ready`, so `createWorkerCommands()` registers `python3` for
`bash -c` and for a direct `spawn(['python3', ...])`. The entry bundle is
`worker-entry.js` and the tool worker is built beside it as
`tool-worker-python.js`; a deployment must serve both.
`scripts/ci/smoke.sh` and `scenarios.sh` build and stage the pair through
`scripts/ci/python-artifacts.sh`, which reuses an existing artifact
directory and otherwise runs `build.sh` once.

`THIRD_PARTY.md`'s "Other components shipped in the image" table is maintained
by hand; when an image is packed with python for distribution, add the CPython
row there (PSF-2.0, `<https://python.org/>`).

## Runtime wiring

```ts
const python = new PythonRuntime({
  backend: new NodeFsBackend(dshNodeFsPromises, { flush: () => host.vfs.flush() }),
  wasm: { url: 'image://python.wasm', load: () => readImageFile('python.wasm') },
  stdlib: { url: 'image://python313.zip', load: () => readImageFile('python313.zip') },
  preopens: [
    { guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' },
    { guestPath: '/dsh/home', hostPath: '/dsh/home' },
    { guestPath: '/tmp', hostPath: '/tmp' },
    { guestPath: '/dsh/tmp', hostPath: '/dsh/tmp' },
  ],
  cwd: '/dsh/workspace',
})

python.installShellDispatch() // bash -c 'python3 …' now resolves here
python.toolbox.has('python3') // true
await python.toolbox.run({ program: 'python3', argv: ['-c', 'print(1)'] })
```

The package is imported from the `@phone-dsh/dsh-wasi-toolbox/python` export
face, so `scripts/pack-image.mjs` stages it as `lib/python.js` (and the worker
entry as `lib/tool-worker-python.js`).

`PythonRuntime` registers `python3` (and the `python` alias the Worker shell
declares) in the real W7 `WasiToolbox` command table. `installShellDispatch()` publishes that table on the Worker global the
shell command table reads (`setWorkerToolbox()`), so `createWorkerCommands()` in
`@phone-dsh/dsh-shell-ext` adds one just-bash command per toolbox program and
`subprocess-xl`'s direct `spawn(['python3', ...])` routes through the same
`toolbox.run()` — there is no second `python3` implementation in the shell. The
stdlib is passed once in the worker `init` message, mounted as a
`ReadOnlyMemoryVfs` layer at `/python-stdlib`, and exposed to the guest as
`/usr/local/lib/python313.zip` with `PYTHONHOME=/usr/local` and
`PYTHONPATH=/usr/local/lib/python313.zip:/usr/local/lib/python-cwd`.
Consequently `zipimport` serves `json`, `re` and `pathlib` from worker memory.
`PYTHONDONTWRITEBYTECODE=1` keeps CPython from trying to write cache files next
to the read-only zip.

The preopens are the namespace's identity roots — `/dsh/workspace`,
`/dsh/home`, `/tmp` and `/dsh/tmp` — generated from the one root table, so
`python3` and `ls`/`cat`/`awk` see the same files under the same names; the
namespace canonicalises `/tmp/**` onto `/dsh/tmp/**`, and a relative `open()`
and `/dsh/workspace/...` hit the same VFS
file. WASI preview1 has no cwd argument, so the read-only stdlib layer also
carries a `sitecustomize.py` (mounted as `/usr/local/lib/python-cwd`,
`cwd-shim.ts`) which applies the dispatch cwd (`PWD`, translated to `/dsh`) with
`os.chdir` before user code runs. Python's `os.getcwd()`, relative opens and
`os.listdir('/dsh/workspace')` therefore match the bash tool's workdir. A
relative *script* operand is resolved against that cwd before dispatch (CPython
resolves the filename during path configuration, before the shim can chdir), so
`python3 exports/x.py` opens the same file `cat exports/x.py` reads and
`sys.argv[0]` is the absolute `/dsh` path. The `-S`, `-E` and `-I` modes skip
or hide the startup hook; those flags are not part of the supported `python3`
surface.

Workspace and home still go through the existing synchronous VFS proxy, so
every Python write is an ordinary DSH write and reaches the WAL sink.
`open("/dsh/workspace/probe.txt", "w")` produces the file on disk through that
path. Cancellation uses the toolbox's existing worker `terminate()`; the 260 MB
`DEFAULT_HOT_INSTANCE_MEMORY_BYTES` ceiling applies.

## HTTP: the host `/v1/http` bridge (G2-FIX-67)

The interpreter has no socket and no `_ssl` module, so stock `urllib` answers
`unknown url type: https` and an `http:` request dies in `socket`. The package
therefore mounts `_xl_http.py` in the same read-only shim layer as
`subprocess` and the startup hook. When the DSH Worker injected loopback
`/v1/http` coordinates it exports `PDSH_PYTHON_HTTP=1`; `sitecustomize.py` then
imports `_xl_http` and installs a synchronous `http.client.HTTPConnection` /
`HTTPSConnection` plus the matching `urllib.request` handlers. Without that
flag the interpreter starts with the stock behaviour, and a missing shim is
ignored rather than breaking every `python3` start.

`_xl_http.py` writes the frozen frame to the private `/__xl__/http` descriptor
served by `src/http-bridge.ts`:

```
request  = u32 header_len | u32 body_len | JSON {op, method, url, headers} | body
response = u32 header_len | JSON {status, reason, headers, bodyBytes} | body
```

Every request starts on the Worker's only egress, `POST /v1/http`; the host
allow-list and host credentials decide the final access. The channel bearer is
injected by the tool worker into the synchronous `XMLHttpRequest` and is never
placed in the guest environment or the VFS. The limits are 1 MiB of headers,
16 MiB of request body and 64 MiB of buffered response body; crossing one is a
structured `OSError`, never a truncated success.

Supported: `urllib.request` GET/HEAD/POST, request headers and body, response
status/reason/headers/body, `4xx`/`5xx` `HTTPError`, direct
`http.client.HTTPSConnection`, and `https:` URLs (the host performs TLS).
Deliberately unsupported and refused rather than faked: proxy `CONNECT`
tunnels, client certificates, FTP, chunked/streaming uploads and live streaming
downloads. Cookie-based auth is not supported by the bridge: guest
`Cookie`/`Cookie2`/`Referer` headers are dropped before egress, and egress
`Set-Cookie`/`Set-Cookie2`/`Clear-Site-Data`/`Alt-Svc` are stripped by the
host before WebKit applies them, so an upstream cannot seed or clear the
loopback launch cookie and Python never sees those response headers. A
`Set-Cookie` observed by a fake engine is never replayed as a request cookie.
A response is buffered in full before Python sees it; an engine that cannot
return an `ArrayBuffer` body is a structured transport failure, not a lossy
text decode. TLS verification and the origin allow-list are the host's
responsibility because the interpreter has no `ssl`.

`3xx` handling: redirects the host egress policy itself permits and follows
remain host operations. The host strips `Location` from every residual `3xx`
on `/v1/http` while preserving status and body, so a browser XHR cannot follow
an upstream `Location` on the authenticated loopback origin with the channel
bearer. A residual `3xx` without `Location` reaches the shim as a non-success
status and `urllib` raises `HTTPError`; automatic redirects through the real
bridge are deliberately unsupported. The shim's `HTTPRedirectHandler` is
exercised only with a fake `_call`, which proves library mechanics, not the
production egress path. Synchronous XHR on iOS WebKit and device-level
guest-token isolation are **NOT_VERIFIED** in this repository's Linux gates;
the real CPython/WASI artifact branch runs against a fake `/v1/http` route, and
the Mac commands are recorded in the plugin tests.

## subprocess: a nested interpreter with piped stdio

WASI preview1 has no process model, so stock CPython's `subprocess.Popen`
raises `OSError [Errno 58] wasi does not support processes`. Python tasks that
shell out — a `unittest` suite driving its own CLI, a script orchestrating
snippets — therefore used to fail as a whole. The workspace ships two read-only
shim files instead:

* `subprocess.py` shadows the stdlib module because the shim directory is the
  first entry on `PYTHONPATH`. It loads the *real* `subprocess` from the stdlib
  zip, patches `Popen` on it and hands that module to `sys.modules`, so
  `import subprocess`, `subprocess.run`, `call`, `check_output`, `check_call`
  and `CalledProcessError` are the standard implementations. A command that
  never imports `subprocess` pays nothing: the shim directory is one `sys.path`
  entry with two small files.
* `_xl_subprocess.py` is the replacement `Popen`. It opens the private
  `/__xl__/spawn` descriptor served by our WASI host, writes one framed request
  (`argv`, `env`, `cwd`, stdin bytes) and reads one framed
  response (exit code, stdout, stderr). The WASI host runs a fresh interpreter
  instance in the same tool worker, from the same `WebAssembly.Module`, with
  the same preopen table and the same `WasiVfs` object as the parent command:
  a child write is an ordinary DSH write through the one VFS proxy, and the
  command-boundary flush covers it (G2-FIX-61). The snapshot fallback path
  works the same way; the child's mutations join the parent's queued writes.

Supported `Popen` surface: list or string `args`, `executable`, `stdin`,
`stdout`, `stderr` (`PIPE`, `DEVNULL`, `STDOUT`, file objects and descriptors),
`input=`/`communicate()`, `capture_output=`, `text`/`universal_newlines`/
`encoding`/`errors`, `cwd=` (default: the caller's cwd), `env=` (inherited by
default), `wait`, `poll`, `kill`/`terminate` and the context-manager protocol.
Exit codes propagate exactly, including a trap (134) and the memory ceiling
(137). `shell=True` and the OS-specific `preexec_fn`/`pass_fds`/`user`/`group`/
`umask`/session flags fail loud with `NotImplementedError` instead of pretending
to work. `timeout=` on `subprocess.run`, `wait` or `communicate` is accepted
but not enforced: nested interpreters execute synchronously on the same Worker
thread, so this runtime cannot preempt them. The child runs to completion, its
result is returned as usual (no `TimeoutExpired`), and the interpreter prints
one notice to stderr the first time a deadline is ignored. The outer command's
own timeout still bounds the whole run. Combined stdout/stderr of one nested
child is capped at 16 MiB; crossing it stops the child at that write (every
later write traps too) and the caller gets `OSError(EFBIG)`.

Program resolution uses the same command table the shell dispatches: `sys.executable`
(the wasi build sets it to the empty string), the empty spelling, `python3` and
the table's aliases (`python`) all name this interpreter. Any other program is
not runnable inside the single-interpreter tool worker, so `Popen` raises
`NotImplementedError` **at construction** with the available programs in the
message, for example
`subprocess: 'ls' is not available in the WASI toolbox (available programs:
python3, python)`; it never returns a fabricated status or output.

Each nested level is a full interpreter start on the same thread; the host caps
the chain at eight levels and turns a deeper one into a loud `OSError`. A
nested `python3 -c pass` measured 28 ms (median of 5) in this worktree, on the
same host numbers as the table above. A parent and a child interpreter are both
live while the child runs, so the transient peak is roughly two interpreters;
that and WebKit's re-entrant wasm execution are **NOT_VERIFIED** on iOS, and
the W3 probes own the measurement. Nested stdout and stderr share a 16 MiB
budget enforced in the live WASI write callbacks. Crossing it unwinds the
synchronous child and returns a structured `output-limit` refusal, which the
Python shim exposes as `OSError(EFBIG)`. The collector keeps at most the budget
of copied output; one currently delivered WASI write chunk may also be live.
Standard input not given through
`input=`/`stdin=PIPE` is delivered as EOF: a WASI dispatch has no live terminal
to inherit.

## Measurements

Environment: Apple Silicon (arm64), macOS 26.4, Node.js 24.19.0, CPython 3.13.17
built with WASI SDK 25.0, W7 tool worker in a Node worker thread. These are
host numbers, not phone numbers: iOS/WebKit performance is **NOT_VERIFIED**.
The benchmark drives the real toolbox route, so it includes worker messaging
and the WASI host, not just interpreter time.

| Measurement | Time |
| --- | --- |
| cold start (spawn worker + compile wasm + CPython init + `pass`) | 132 ms |
| warm start (fresh interpreter in the warm worker + `pass`), median of 5 | 28 ms |
| `import json, re, pathlib`, median of 5 | 200 ms |
| 1 MiB JSON on stdin + `json.loads`, median of 5 | 157 ms |
| peak interpreter linear memory | 20 MiB (20,971,520 bytes) |
| stdlib zip reads that crossed the VFS proxy | 0 |

The import run dominates because each `python3` invocation is a fresh
interpreter and `zipimport` compiles the pure-Python sources from the stored
zip. Precompiling `.pyc` entries is a possible later optimisation; it is not
needed for the go decision. The 1 MiB JSON figure includes interpreter start,
stdin transit and the parse. 385 VFS proxy calls were observed for path probes
during the same benchmark; none touched the stdlib zip.

These numbers were measured on the compression-linked artifact, in this
worktree, in one benchmark run (median of five); they replace the earlier
numbers taken before zlib, bzip2 and liblzma were linked in.

## What works

The spike imported and ran, from the zipped stdlib: `json`, `re`, `pathlib`,
`math`, `datetime`, `hashlib` (built-in SHA implementations), `random`,
`statistics`, `csv`, `decimal`, `fractions`, `collections`, `itertools`,
`functools`, `typing`, `unittest` and `asyncio`. The
`socket` and `subprocess` modules import, but constructing a socket or a
process fails (see below). File I/O through `/dsh/workspace` works end to end,
including `os.getcwd()`, relative opens and `os.listdir`, and the bytes reach
the host backend.
`sys.platform == "wasi"` and `os.uname().machine == "wasm32"`, as CPython
documents for this port.

Compression is part of the built interpreter: `import zlib, bz2, lzma` works,
`zlib`, `bz2` and `lzma` compress/decompress roundtrip, and
`tarfile.open(name, "w:gz")` writes and reads a real gzip archive on the VFS
(`gzip` and `zipfile` come from the zipped stdlib). The `zlib` runtime version
in this build is 1.3.1.

## What does not work

| Area | Result |
| --- | --- |
| `pip` / package installation | unavailable: `ensurepip` is not shipped; network access exists only through the host `/v1/http` allow-list |
| C extensions | only modules statically linked into `python.wasm`; no dynamic extension loading in this build |
| `_ctypes` | missing (configure does not build it for wasm32-wasi) |
| `_sqlite3`, `_ssl` | missing; `sqlite3` and `ssl` imports fail with `ModuleNotFoundError` (no wasm32-wasi SQLite/OpenSSL is pinned) |
| sockets | `socket` imports, but `socket.socket()` fails with `OSError [Errno 58] Not supported`; WASI preview1 has no usable network stack and the host's `sock_*` imports answer `ENOSYS`. Standard-library HTTP goes through the `/v1/http` bridge above, not a socket |
| `subprocess` | works through the nested-interpreter bridge; only the interpreter itself is runnable, other programs fail loud (see above), and `shell=True` is refused |
| native code, threads, `mmap`, dynamic linking | not enabled in this build |

There is also no host filesystem outside the preopens: paths outside
`/dsh/workspace`, `/dsh/home`, `/dsh/tmp` and the stdlib mount answer a
capability error.

## Recommendation

Ship `python3` as a toolbox command for scripts that use the pure-Python
standard library, the workspace, and nested interpreter calls through
`subprocess` and the compression standard library. The binary and stored stdlib
together are 38.7 MiB on disk, and a live interpreter peaks at about 20 MiB,
comfortably inside the 260 MB WASI
budget and the 160 MB workspace VFS budget. Cold start is ~0.13 s, warm commands
are ~28 ms before imports, and a nested interpreter is ~28 ms, so an agent loop
can call Python several times per turn without hurting responsiveness on the
Mac host. Keep the build in the image pipeline rather than the repository and
pin it through `lockfile.json`; `pip`, native wheels, network clients and
non-interpreter programs remain out of scope for the WASI row.

Before relying on it on a phone: re-run `--check` and the build on the image
builder, run the real benchmark with `PDSH_PYTHON_WASM` (below), and run the same
script under the iPhone 17 Pro simulator. The W3 SAB/COI probe remains the gate
for file I/O; imports from the in-worker stdlib do not depend on it.

## Tests

`npm test` from `plugins` runs `wasi-toolbox/python/runtime.test.ts`:

* the stub module proves the toolbox route, stdio and stdin;
* `createPythonVfs` proves the zip is read from the in-worker layer with zero
  proxy calls and that writes to the layer answer `EROFS`;
* the benchmark proves cold/warm/import/JSON measurement and stdin delivery.

`wasi-toolbox/python/compression.test.ts` is the regression gate for this
capability:

* `build.sh --check` must fail an artifact directory whose interpreter cannot
  run the compression probe (the WAT stub stands in for a pre-fix build), while
  a plan-only check with no explicit artifact passes, says the capability is
  not verified, and names zlib/bz2/lzma and the probe;
* the spec gate command (`build.sh --check`, default output directory) must
  pass, and `build.sh --check --out DIR` must pass on the exact artifact the
  compression tests execute (the real build directory, so its `sizes.json` and
  `compression.json` are re-validated), so the test log shows the probe passing
  on a produced interpreter and not only on the stub that has to fail;
* `python3 -c 'import zlib, bz2, lzma'` runs through the real Worker
  composition (`PythonRuntime` + the python tool worker) and must exit 0;
* a `tarfile` `w:gz` write/read roundtrip runs through the same composition,
  and the archive the Worker produced is gunzipped on the host and inspected;
* the full build probe (`COMPRESSION_PROBE_PROGRAM`) must report no problems.

The artifact tests execute an artifact selected by `PDSH_PYTHON_WASM` (plus
optional `PDSH_PYTHON_STDLIB`), else `PDSH_PYTHON_ARTIFACTS`, else the default
`$TMPDIR/pdsh-python-wasi` directory. The two explicit selections are trusted: a
bad artifact fails the tests. The default directory is shared machine state, so
`ensurePythonArtifacts` classifies it by its build reports and, when the pair is
absent, incomplete or pre-fix, runs `build.sh --check` on that same managed
directory before the tests execute:

* a pair without `compression.json` is a pre-fix build or a hand-copied pair;
  the pinned `build.sh --check` rebuilds it and the new pair is probed, so the
  four capability tests always run against a verified interpreter instead of
  skipping (the state that once let the original `ModuleNotFoundError: No
  module named 'zlib'` defect ship untested);
* a pair that carries both `sizes.json` and `compression.json` is a current
  build's claim: both sha256 digests, `compression.modules` and
  `compression.tarfileGzip` are checked, then `verify-compression.mjs` runs.
  A hash mismatch or a failed probe is a broken artifact and fails the suite,
  so a regression in the stamped build is still caught (a stamped pair is not
  silently rebuilt away);
* if the pinned build cannot produce a verified pair, the suite fails with the
  build output (`ensurePythonArtifacts` turns that into a failing test); there
  is no skip path left for the compression tests.

The selection and provisioning policy is covered by
`wasi-toolbox/python/python-artifacts.test.ts`.

Two release-path callers still reuse an existing pair without running this
probe, and both are outside this package's write scope:
`scripts/ci/python-artifacts.sh` returns an existing directory as-is, and
`scripts/pack-image.mjs --python` stages the pair without checking it. The
default `$TMPDIR/pdsh-python-wasi` directory is repaired by `build.sh --check`
and by the compression tests, so a packaging run after either one stages a
verified pair; but a caller that points `--python`/`PDSH_PYTHON_ARTIFACTS` at a
different stale directory bypasses the probe entirely. Until those callers run
`build.sh --check --out <dir>` (or `verify-compression.mjs`) before reuse, that
directory can still be packed. This is recorded as a contract gap: the image
gate should stage python through the probe, and `plugins/THIRD_PARTY.md`
needs the CPython, zlib, bzip2 and liblzma rows when python is shipped.

`plugins/tests/wasi-python-subprocess.test.ts` (gate:
`node --test plugins/tests/wasi-python-subprocess.test.mjs`) covers the
subprocess bridge end to end against the real artifact: capture_output, exit
code propagation, `input=`/`communicate()`, a ten-case `unittest` suite driving
subprocess, a nested child's VFS write reaching the shared backend and the
command-boundary flush, the snapshot fallback, env/cwd inheritance, nesting
again, the loud unknown-program failure, and the host protocol itself.
It also checks that `timeout=` is accepted and the child's result returned with
a single notice, that combined stdout/stderr overflow (including an errno
diagnostic that crosses the budget) stops the child and settles the outer
Python command through the real CPython artifact.

The real CPython benchmark is skipped unless an artifact is supplied:

```sh
PDSH_PYTHON_WASM="$TMPDIR/pdsh-python-wasi/python.wasm" \
PDSH_PYTHON_STDLIB="$TMPDIR/pdsh-python-wasi/python313.zip" \
  npm test
```

The test asserts `pythonVersion` is 3.13.x, that the imports succeed, that a
1 MiB JSON document is parsed, and that **no stdlib zip read crossed the VFS
proxy**.

## Licence

The build consumes CPython (PSF-2.0), WASI SDK (Apache-2.0 with
LLVM-exception), zlib 1.3.1 (Zlib licence), bzip2 1.0.8 (bzip2-1.0.6, a
BSD-style licence) and liblzma 5.6.4 (0BSD; only `liblzma` is built, the xz
command line tools and scripts are disabled). All five are recorded in
`lockfile.json`, and none is an npm dependency: they are build-time sources of
`python.wasm`. Pyodide (MPL-2.0) is not used.

`plugins/THIRD_PARTY.md` is outside this package's write scope. When an
image is packed with python for distribution, the "Other components shipped in
the image" table needs the CPython row (PSF-2.0, `<https://python.org/>`) and
the three compression rows (Zlib, bzip2-1.0.6, 0BSD) from the table above.
