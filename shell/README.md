# pdsh-shell

Read-only native accelerators for the phone-dsh phone DSH Worker.

`pdsh-shell` is a Rust workspace. The tracked `pdsh-ffi` C ABI links the same
production registry the crates test; there is no generated or copied source in
the Apple build.

| Crate | Kind | Purpose |
|---|---|---|
| `pdsh-core` | library | mount-table path sandbox, read-only VFS, cancellation, bounded output, limits, host bridge, command registry and capability JSON |
| `pdsh-rg` | library | `rg` (ripgrep-compatible read-only search) |
| `pdsh-jaq` | library | `jaq` and its `jq` alias |
| `pdsh-ts` | library | `ts-parse` and `ts-query` (tree-sitter) |
| `pdsh-phone` | library | `phone` and `ctx` host-bridge accelerators |
| `pdsh-all` | library | the complete production registry: `rg`, `jaq`/`jq`, `ts-parse`, `ts-query`, `phone`, `ctx` |
| `pdsh-ffi` | staticlib + rlib | C ABI (`include/xzshell.h`) that the Swift host links; `pdsh_version`, `pdsh_caps_json`, `pdsh_caps_json_with_bridge`, `pdsh_run`, `pdsh_cancel`, `pdsh_join` |
| `pdsh-jaq-wasm` | binary | Worker `wasm32-wasip1` jq-compatible engine, built by `plugins/wasi-toolbox/jq/build.sh`; separate from the native accelerator registry |
| `pdsh-brush-wasm` | wasm library | optional bash-compatible Wasm spike, not part of the Apple accelerator build |

The native side is a **read-only accelerator set** (PLAN §2.4, D12), never a
general shell and never a writer of the workspace. `bash -c` and every command
that can write the workspace stay in the Worker; only the names advertised in
the host HELLO caps (`accelerator:rg`, `accelerator:jaq`, `accelerator:jq`,
`accelerator:ts-parse`, `accelerator:ts-query`, `accelerator:phone`,
`accelerator:ctx`) may be forwarded to this library.

The production `pdsh-all` registry advertises `rg`, `jaq` (also the `jq`
alias), `ts-parse`, `ts-query`, and — only when a host tool bridge is present —
`phone` and `ctx`. `pdsh_caps_json` reports the complete diagnostic registry;
`pdsh_caps_json_with_bridge(0, …)` and `accelerator_names_with_bridge(false)`
report only what a caller without a `call_tool` callback can execute. The
Swift provider uses the bridge-aware form and never advertises a command it
cannot run. The diagnostic `echo` and `pdsh-caps` commands exist only in the
FFI's test registry and are never advertised. The phone UI displays only the
linked library's capabilities.

## Layout

```
shell/
  Cargo.toml            workspace (resolver 2)
  rust-toolchain.toml   stable toolchain
  build-apple.sh        iOS/iOS-sim/macOS slices and dist/PDSHShell.xcframework
  include/xzshell.h     hand-written C ABI; checked against the exports by a test
  crates/pdsh-core/     sandbox, VFS, output, limits, commands, registry
  crates/pdsh-rg/       ripgrep-compatible search
  crates/pdsh-jaq/      jq-compatible filters
  crates/pdsh-ts/       tree-sitter parse/query
  crates/pdsh-phone/    host-bridge phone/ctx
  crates/pdsh-all/      complete production registry
  crates/pdsh-ffi/      extern "C" entry points and callback bridge
  crates/pdsh-jaq-wasm/  Worker jq WASI executable (not linked by the FFI)
  crates/pdsh-brush-wasm/ optional Wasm shell spike (not linked by the FFI)
```

## Sandbox

Guest paths are absolute under `/dsh`; the mount table maps `/dsh/workspace` and
`/dsh/home` onto host directories. `MountTable::resolve` rejects, with a typed
`SandboxError`:

- the empty path and NUL bytes;
- relative paths at the VFS layer (the command context resolves them against
  its cwd first);
- any `..` that walks above the guest root;
- absolute guest paths outside every mount; and
- symlinks whose target canonicalizes outside the mount root (`std::fs::canonicalize`).

Every existing ancestor of a missing path is checked, so a symlinked directory
cannot hide a later file. `Vfs` has no write, create, remove, rename or chmod
method: an accelerator cannot mutate the workspace even if it tries.

## Commands and context

A command implements `Command::run(&self, argv, ctx)` and returns an exit code.
`Ctx` carries the VFS, guest cwd, environment, stdout/stderr sinks, cancel
token, limits and the host bridge.

The environment is forced to `TERM=dumb`, `NO_COLOR=1` and `LANG=C.UTF-8`; a
request cannot override these keys.

Commands must check cancellation at least once per processed file and at least
once per 64 KiB of output. `Ctx::begin_file`, `Ctx::open_read`, `Ctx::read_file`,
`Ctx::emit_stdout` and `Ctx::emit_stderr` do this automatically. A cancelled
command returns exit code 130.

`Limits` are:

| Field | Default | Meaning |
|---|---|---|
| `timeout` | 30 s (FFI `timeout_ms`; 0 = none) | wall-clock deadline; the FFI watchdog cancels the token |
| `max_output_bytes` | 1 MiB | captured bytes per stream |
| `max_files` | 10,000 | files one command may open |
| `max_file_bytes` | 15 MiB | bytes one command may read from one file |

Output capture counts every byte. When a stream exceeds its budget the sink
keeps the first 60 percent and the last 40 percent of the budget and inserts a
marker line of the form `[pdsh-shell truncated N bytes]` between them. The marker
is not counted as output data.

The capability JSON is:

```json
{"accelerators":["rg"],"version":"0.1.0","limits":{"timeout":30000,"max_output_bytes":1048576,"max_files":10000,"max_file_bytes":15728640}}
```

Without a host bridge the `phone`/`ctx` names are absent from that array and
from the run registry, so a request for them is an unknown command (127)
instead of a capability the library claims but cannot satisfy.

## C ABI

`include/xzshell.h` declares `pdsh_version`, `pdsh_caps_json`,
`pdsh_caps_json_with_bridge`, `pdsh_run`, `pdsh_cancel` and `pdsh_join`, plus
`XzRequest`, `XzCallbacks` and `XzLimits`. `pdsh_run` copies the request, starts
a worker thread and returns a positive handle immediately; `pdsh_join` waits and
returns the exit code. `on_stdout`/`on_stderr` receive the retained bytes once,
followed by `on_exit`, all from the worker thread. The `call_tool` callback
forwards `phone`/`ctx` tool calls to the host app; when it is NULL those two
commands are neither registered nor advertised.

Exit codes: 0 success, 70 caught panic, 124 deadline, 127 unknown command,
130 cancelled. A panic is caught with `catch_unwind` and reported as exit 70
plus an `pdsh-shell: panic: ...` stderr line.

A unit test parses the header, the exported function definitions and the
expected symbol list and fails when they diverge, and the integration tests in
`crates/pdsh-ffi/tests/native_provider.rs` drive the production registry
through the exported functions.

## Build and test

```sh
export PATH="$HOME/.cargo/bin:$PATH"
cargo build --workspace
cargo test --workspace
cargo build -p pdsh-ffi --release --target aarch64-apple-ios
bash build-apple.sh --check          # macOS slice only
bash build-apple.sh                  # all slices + dist/PDSHShell.xcframework
```

`build-apple.sh` builds the tracked `pdsh-ffi` crate directly with
`--locked`; it does not generate or copy crate sources. The full script needs
the `aarch64-apple-ios`, `aarch64-apple-ios-sim` and `aarch64-apple-darwin`
rustup targets and Xcode. The produced static library is `libpdsh_ffi.a`; the
xcframework is `dist/PDSHShell.xcframework` with `xzshell.h` and
`module.modulemap` (module `PDSHShell`) in its Headers directory. The iOS
slices compile; running them on an iPhone is NOT_VERIFIED. The SwiftPM target
links the XCFramework only when `PDSH_WITH_XZSHELL=1` (or the historical
`PDSH_WITH_SHELL=1`) and the directory exists; otherwise `PhoneDSHShell`
compiles its honest stub, which advertises nothing and fails every run with
`notLinked`.

There are no third-party Rust dependencies added for the FFI wiring; `pdsh-all`
uses the existing permissive accelerator libraries recorded in
`THIRD_PARTY.md`, and `Cargo.lock` is checked in for reproducible builds.
