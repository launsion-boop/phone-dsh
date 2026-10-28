# jq WASI engine

This directory is the build/probe side of the Worker's jq-compatible engine.
The executable is the repository's `pdsh-jaq-wasm` crate
(`shell/crates/pdsh-jaq-wasm`) over the MIT jaq-core/jaq-std/jaq-json crates
already pinned in `shell/Cargo.lock`; it is a real filter engine, not a token
rewrite. The Worker runtime wiring is `plugins/worker-entry/src/jq-toolbox.ts`;
the shell command still lives at `plugins/shell-ext/src/jq.ts` and delegates to
the registered `jq-wasi` program when the image carries the artifact.

## What the engine implements

- `input`, `inputs`, `input_line_number` over one lazy, shared input cursor
  (conditionals, `select`, `first`/`last`/`limit`, function arguments,
  `reduce`/`foreach`, `break` and user definitions use jaq's real semantics);
- `input` at EOF raises jq's real catchable `"break"` error value (never an
  internal marker); a parse error is a catchable error value while an
  unreadable operand is reported and forces exit 2 without being catchable;
- `input_line_number` across JSON and `-R` operands (raw line numbers restart
  per operand, including lines that cross an operand boundary);
- lazy `-s`, including `-n -s` never opening an operand and the native
  `[]`/output-then-open-error ordering when a file is missing;
- raw input assembled line by line: a later operand is opened only when the
  current line or the real `-s`/`inputs` consumption needs it, so
  `-n -R first(inputs)` returns the first newline-terminated line without
  reporting a missing later file; JSON peeks for a BOM only while the bytes
  could still be that prefix, so a self-contained `{}` never opens the next
  operand;
- `$ARGS` (`--args`/`--jsonargs`), `$ENV`, and `$__loc__` at the line where the
  reference appears (including inside `def` and string interpolation);
- jq 1.6 exit classes: 0 success, 1 `-e` false/null, 2 usage/open error,
  3 compile error, 4 input parse error, 5 runtime/break;
- invalid UTF-8 replacement inside JSON strings; a parse error outside them.

`jq --version` keeps the `jq-1.6` compatibility prefix for scripts, but the
line also names the real implementation:
`jq-1.6 (pdsh-jaq-wasm; jaq-core 3.1.2 + jaq-std 3.0.4 + jaq-json 2.0.3; ...)`.
It never claims to be the jq 1.6 binary. The GNU convention wrapper delegates
`jq --version` to the bound engine, so the production shell prints this line
instead of `jq (just-bash) 3.6.0`; without an engine it keeps the shim banner.

It does **not** claim complete jq 1.6 compatibility. jaq's error text, some
formatting/edge semantics and `--color` differ; see
the plugin tests
for the stable 52-command native comparison (plus a separate
trailing-empty-operand regression) and the remaining deviations.

## Build and probe

```sh
bash plugins/wasi-toolbox/jq/build.sh --out /tmp/pdsh-jq-wasi
# -> jq.wasm, engine.json, sizes.json; verify.mjs executes real input probes
bash scripts/ci/jq-artifacts.sh   # default $TMPDIR/pdsh-jq-wasi cache
```

Artifacts are build products and are never committed. Requires a Rust stable
toolchain with the `wasm32-wasip1` target (the script installs the target when
`rustup` is available). The toolchain is only needed for a build/rebuild:
`build.sh --check` verifies an existing source-bound artifact without cargo.
Pack them with
`plugins/scripts/pack-image.mjs --jq <dir>` (or `PDSH_JQ_ARTIFACTS`); without
that flag the image has no engine and `jq` stays on the fail-loud shim.

## Source-bound artifacts

`source-fingerprint.ts` hashes the crate sources, `shell/Cargo.toml`,
`shell/Cargo.lock`, `shell/rust-toolchain.toml` and the build/probe scripts.
Both `engine.json` and `sizes.json` record that fingerprint, the actual wasm
sha256/byte count and the rustc/cargo/target identity. Consequences:

- `build.sh --check` verifies the reports against the current sources; a source
  edit makes the default artifact rebuild and makes an explicit `--out`
  artifact fail with the rebuild command instead of reusing stale bytes.
- `pack-image.mjs --jq` refuses a source fingerprint that does not name this
  checkout, an `engine.json` that describes other wasm bytes, or a swapped
  report pair.
- Worker boot verifies the staged wasm sha256/byte count against
  `engine.json` and requires the source binding before advertising `jq`.

## Output bounds

The shell collects jq stdout/stderr through a per-stream cap
(`4 * PDSH_SHELL_MAX_OUTPUT_BYTES`, at least 256 KiB) and passes the same caps
to `WasiToolbox`. Crossing one stops the guest through the normal toolbox
terminate path and reports `E_OUTPUT_LIMIT` with the produced/kept counts;
`AbortSignal` cancellation still drops the worker, and the next run starts a
fresh one. The same limit and collector apply to the directly advertised
`jq-wasi`/`jaq` toolbox commands, so they cannot bypass the `jq` path. The
shell's `boundOutput` remains the user-visible truncation owner; the toolbox
`stdoutBytes`/`stderrBytes` counters are guest bytes and exclude the host cap
diagnostic.
