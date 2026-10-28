# Wasm brush spike — go/no-go report

Status: measured on 2026-10-25 in this worktree (macOS arm64, Node 24.19,
rustc 1.99.1). Nothing here was run on an iPhone; every statement about iOS or
WebKit behaviour is `NOT_VERIFIED`.

## Verdict

**NO-GO for `brush-core` 0.5.0 (crates.io) as the Worker `bash` core.**

The shell engine, the host dispatch hook, the module size and the start-up cost
are all acceptable, and the shell language covers the public corpus almost
completely. The blocker is the released crate's WASI plumbing:

1. `std::io::pipe` is unsupported on `wasm32-wasip1`, and brush-core 0.5.0
   calls it directly. **Pipelines, command substitution `$(...)` and here-docs
   fail.** Five command substitutions and three here-docs in the corpus are
   affected.
2. `std::fs::File::try_clone` is unsupported on `wasm32-wasip1`, and
   brush-core 0.5.0 stores open files as `std::fs::File`, which its `Clone`
   implementation must duplicate. **File redirection (`> file`, `< file`)
   fails**, including the G1 smoke command `bash -c 'echo hi > a.txt'`.

Both are fixed on brush `main` (open files are `Arc<std::fs::File>` and the
wasm platform has an in-memory pipe implementation), but no release containing
those fixes exists on crates.io yet. Without the spike's staged-buffer
workaround, the released crate reaches only 93.3% of the public corpus even
when the host implements every program, below the W5 95% gate. The same
harness therefore points at a **GO for the first brush release after 0.5.0**,
or for a vetted git pin of a commit that contains both changes; see
“Re-evaluation” below.

This crate is a spike: it is not linked into `pdsh-all`/`pdsh-ffi`, and the W5/W7
shell path stays with the JS shell (W5-GAPS, just-bash) until the upstream
release is available.

## What was built

`shell/crates/pdsh-brush-wasm`, a workspace member that is compiled for
`wasm32-wasip1` only:

- `runner`: builds a bash-mode brush shell with the standard builtins, a fixed
  environment (`HOME=/dsh/home`, `PATH`, `LANG=C.UTF-8`, `TERM=dumb`,
  `NO_COLOR=1`), `do_not_inherit_env`, and a current-thread tokio runtime.
- `dispatch`: the host hook. Every command name the host advertises is
  registered as a brush builtin; when brush reaches it the builtin collects
  argv, stdin, cwd and the exported environment and calls `Dispatch::execute`.
  The registration carries the command table id in an unexported shell
  variable, so several shells with different tables can coexist in one
  process. Names that are already brush builtins (`echo`, `cd`, `test`, ...)
  keep their builtin behaviour, as in bash.
- `host`: the four `xl` imports (`xl_host_list_count`, `xl_host_list_name`,
  `xl_host_exec`, `xl_host_cancelled`). The request/response format is
  length-prefixed little-endian (`wire`) and is decoded by the Node harness
  from the same specification.
- `abi`: the reactor ABI the harness calls: `xl_brush_alloc/free`,
  `xl_brush_init`, `xl_brush_reset`, `xl_brush_run`, `xl_brush_stdout`,
  `xl_brush_stderr`, `xl_brush_error`, `xl_brush_version`,
  `xl_brush_pipeline_shim`.
- `pipeline`: a conservative workaround for the missing WASI pipes. A script
  that is exactly one top-level pipeline is executed stage by stage, feeding
  each stage's captured stdout to the next stage's stdin. `pipefail`, `time`
  and pipelines nested in compound commands are not handled.
- Features: `wasm-host` (default) selects the real imports; it is inert on
  non-wasm targets, so `cargo test --workspace` builds and passes on the host.

The WASI configuration is filesystem-only: the module imports exactly the
`wasi_snapshot_preview1` filesystem/clock/randomness/poll functions (18
imports) plus the four `xl` hooks. There is no socket, network or process
import. `WebAssembly.Module.imports()` is asserted in `harness/smoke.mjs`.

Prior art: the conch project (Apache-2.0, <https://github.com/sd2k/conch>)
makes brush run in the browser by vendoring a patched brush fork and adding a
WIT process interface to `SimpleCommand::execute`. This spike keeps the
crates.io pin, so it cannot add that patch; it installs the host names as
builtins instead. No conch code was copied.

## Measurements

Reproduce with:

```sh
cd pdsh-shell
cargo build -p pdsh-brush-wasm --target wasm32-wasip1 --release
node crates/pdsh-brush-wasm/harness/measure.mjs --runs 200
```

| Metric | Value |
|---|---|
| `.wasm` raw | 5,351,308 B (5.10 MiB) |
| `.wasm` brotli (q11) | 955,923 B (933 KiB, 17.9% of raw) |
| `WebAssembly.compile` (Node) | 3.1–3.4 ms |
| instantiate + `wasi.initialize` | 0.82–0.93 ms |
| first `xl_brush_run("echo hi")` (shell build included) | 8.9–10.3 ms |
| warm `echo hi`, n = 200 | p50 0.02 ms, p95 0.02–0.03 ms |
| linear memory after init and after 200 runs | 1,769,472 B (1.69 MiB), unchanged |
| imports | 18 `wasi_snapshot_preview1` + 4 `xl` |
| module version | 0.1.0 |

These are desktop-Node numbers. iOS WebKit instantiation and memory are
`NOT_VERIFIED`.

## Corpus coverage

The public corpus is `plugins/tools/shell-corpus/corpus/public.jsonl`
(420 commands). The runner is `harness/brush-runner.mjs`; every command starts
from the same scratch fixture as the `runtime-js` evaluator.

```sh
node plugins/tools/shell-corpus/coverage.mjs \
  --runner brush-wasm \
  --runner-module shell/crates/pdsh-brush-wasm/harness/brush-runner.mjs \
  --out shell/target/pdsh-brush-coverage-demo

PDSH_BRUSH_MODE=stub node plugins/tools/shell-corpus/coverage.mjs \
  --runner brush-wasm \
  --runner-module shell/crates/pdsh-brush-wasm/harness/brush-runner.mjs \
  --out shell/target/pdsh-brush-coverage-stub
```

`demo` runs the harness' small coreutils host table for real. `stub`
advertises every program named by the corpus and returns success without
output, so the result measures shell-language acceptance rather than which
programs the host implements (the W5-GAPS `shell-ext` table is the real
program set).

| Run | ok | syntax-unsupported | command-missing | runtime-error | coverage |
|---|---:|---:|---:|---:|---:|
| demo host | 169 | 2 | 240 | 9 | **40.2%** |
| stub host (shell language) | 407 | 2 | 0 | 11 | **96.9%** |

Demo mode's 240 `command-missing` are programs the harness deliberately does
not implement: `git` 64, `npm` 26, `curl` 25, `pnpm` 19, `npx` 17, `node` 9,
and the rest of the package/build/network toolchains. They are a property of
the demo table, not of brush.

Stub mode by category: files 59/60, text 59/60, git 60/60, package 60/60,
build-test 60/60, script 49/60, network 60/60.

**The stub number is not plain brush-core.** 15 of the 420 commands are
exactly one top-level pipeline and pass only through the staged-buffer
workaround (for example `cat data/words.txt | tr a-z A-Z`). Without the
workaround, brush-core 0.5.0 scores 392/420 = **93.3%** in stub mode, below
the W5 95% gate. The workaround raises it to 96.9%, but it is not brush's pipe
implementation: it does not cover pipelines nested in loops/subshells, does not
implement `pipefail`, and gives no streaming. The 15 commands are counted as
`ok` in the table above because they do run; they are not evidence that
brush-core 0.5.0 supports pipes.

The 14 stub failures are:

| Cause | Count | Commands |
|---|---:|---|
| command substitution (`std::io::pipe`) | 5 | `echo "$(pwd)"`, `files=$(ls)`, `echo $(printf "abc")`, `x=$(seq 1 3)`, `echo "$(basename …)"` |
| here-doc (`std::io::pipe`) | 3 | `cat <<EOF`, `cat <<'EOF'`, `cat <<-EOF` |
| file redirection (`File::try_clone`) | 2 | `echo hello > out.txt && cat out.txt`, `echo one > out.txt; …` |
| stub-mode artefact (`mkdir` is a no-op stub, the real `test -d` then fails) | 2 | `mkdir -p a/b/c && test -d a/b/c`, `mkdir -p build && cd build && pwd` |
| correct non-zero status, mis-bucketed by the corpus tool | 1 | `! true` |

So, with a complete host table, the released crate is limited by **10
commands blocked outright by its WASI implementation** plus **15 top-level
pipelines that need the workaround**. The ten are core bash idioms
(`$(...)`, `> file`, here-docs), not a long tail: they are ten of the eleven
`script`-category failures and the single `text`-category failure. A
`bash -c` executor that cannot run them cannot replace the current shell; the
15 pipeline commands are the same story at a smaller scale.

There is **no just-bash runner report in this tree** (`plugins/shell-ext`
does not exist yet), so the requested delta is **N/A**. When W5-GAPS lands
`shell-ext`, rerun the same coverage command against its runner module and
compare the `coverage-report.json` files; no tool changes are needed.

## Integration sketch

How `plugins/shell-ext` would host this module (the TS host itself is out
of this task's write scope):

1. **Instantiation.** W7 `wasi-toolbox` compiles the module once
   (`WebAssembly.compile`) and instantiates one reactor per `bash -c` call, or
   one hot instance reset with `xl_brush_reset()`. A new `bash -c` is a fresh
   shell in DSH, so per-call shells are the safe default; the measured
   0.8 ms instantiate / 10 ms first-command cost makes that affordable.
2. **WASI filesystem.** Preopen one `/dsh` subtree backed by the VFS proxy,
   exactly as the harness preopens one host directory. The proxy must
   implement the preview1 calls the module imports and route writes through
   the existing VFS sink/`mseq` machinery; `/dsh/tmp` stays volatile. No
   network or process capability is granted.
3. **Command table.** shell-ext implements the coreutils subset on the VFS and
   advertises those names through `xl_host_list_count`/`xl_host_list_name`.
   Accelerators (`rg`, `jaq`, `ts-parse`, `ts-query`, `phone`, `ctx`) stay
   host-side per D12: the dispatch hook would forward them over
   `__PDSH_CHANNEL__` `EXEC_REQ`, but the current `xl_host_exec` is a
   synchronous import while the channel is asynchronous. A production host
   must either implement a synchronous in-Worker path (VFS-only commands) or
   block on the channel with a `SharedArrayBuffer` + `Atomics.wait` when
   `crossOriginIsolated` (the W4 SAB probe decides); otherwise the accelerator
   round-trip needs an asynchronous ABI (brush's builtins are `async`, so the
   guest side can await; WebAssembly imports cannot).
4. **Output.** The spike ABI batches stdout/stderr (4 MiB cap per stream) and
   returns them after the script. The Worker wants `EXEC_EVT` NDJSON chunks;
   adding an imported `xl_host_write(fd, ptr, len)` to the same `xl` module is
   a small follow-up, and the `CaptureStream` in `runner` becomes a streaming
   sink.
5. **Cancellation.** brush-core 0.5.0 exposes no cancellation hook. The
   dispatch flag stops the next external command, but a running command or a
   long shell loop cannot be interrupted from JS, because the whole script
   runs inside one synchronous `xl_brush_run` call. Hard cancellation is
   therefore “terminate the instance/Worker” (the W7 hot-instance +
   terminate model), losing shell state; a per-call shell makes that
   acceptable. An in-guest cooperative check would need an upstream hook.
6. **Shell-ext commands.** Any command the host can answer synchronously can
   be plugged in by advertising its name; no brush change is required for
   that part. This includes the W5-GAPS pure-TS commands.

## Risks

| Risk | Assessment |
|---|---|
| **brush 0.5.0 WASI pipes / files** | Blocking (see verdict). Fixed on upstream `main`, unreleased. Pin exactly; re-test on every bump. |
| **brush API churn** | `brush-core` changes `OpenFile`, `sys::pipes`, `ShellExtensions` and the wasm task model between minor releases. The crate pins `=0.5.0`; a bump is a small, reviewable code change but needs a full harness rerun. |
| **WASI 0.3 / preview1** | The module targets `wasm32-wasip1` (preview1), the WASI target Rust stable emits, and Node's `node:wasi` drives it. WASI 0.3 (component model/async) would replace the host ABI, not extend it; no 0.3 support was required or tested here. Keep the VFS proxy behind its own versioned boundary. iOS WebKit hosting is `NOT_VERIFIED`. |
| **`spawn_blocking` on wasm** | brush 0.5.0 runs builtins in an owned shell through `tokio::task::spawn_blocking`, which is unsupported on wasm. Multi-command pipelines already fail earlier, so the spike never reaches it; after the upstream pipe fix this path must be re-tested (upstream added a wasm task module). |
| **Unknown-command status** | On wasm brush's `PathExt::executable()` always returns true, so an unadvertised name reaches the (unsupported) process spawn and reports 126 “failed to execute command”, not 127. The host must advertise every supported name; the corpus runner maps the message to `missingProgram`. |
| **Size** | 933 KiB brotli / 5.1 MiB raw on top of the Worker bundle, for a shell that (in 0.5.0) cannot yet redirect files. Acceptable only after the upstream fix; measure against the W3 memory budget once the Worker bundle exists. |
| **Output cap** | The ABI captures at most 4 MiB per stream; a streaming hook is required for large outputs. |
| **Licences** | MIT throughout; the selected graph has no GPL/LGPL/AGPL option. `terminfo` (WTFPL, Unix host only) and `r-efi` (tri-licensed, MIT/Apache selected) are called out in `THIRD_PARTY.md`. |
| **Device behaviour** | All numbers are macOS/Node. iOS WebKit instantiation, memory and JIT behaviour are `NOT_VERIFIED`; the W3 probe package is the place to measure them. |

## Re-evaluation

The verdict flips to GO when a published `brush-core` release contains both
upstream changes:

- `brush-core/src/openfiles.rs`: `OpenFile::File(Arc<std::fs::File>)` with
  clone-by-`Arc` (no `File::try_clone` syscall); and
- `brush-core/src/sys/wasm/pipes.rs`: in-memory WASI pipes wired into
  `commands.rs`/`interp.rs` instead of `std::io::pipe`.

The code to re-run is already here: drop the `pipeline` workaround, rebuild,
and run `harness/smoke.mjs` plus the two coverage commands above. The expected
result is `echo hi | cat`, `echo hi > a.txt`, `$(...)` and here-docs passing,
with the same size and start-up numbers. (This paragraph is source inspection,
not a measurement: upstream `main` was read at commit e37b3c9 in this worktree,
but the spike crate was not rebuilt against it.)

## Reproduce the required checks

```sh
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
cd pdsh-shell
cargo build -p pdsh-brush-wasm --target wasm32-wasip1 --release
cargo test -p pdsh-brush-wasm
node crates/pdsh-brush-wasm/harness/smoke.mjs
```
