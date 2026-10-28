# CPython test fixtures

`stub-python.wasm` is the 567-byte stand-in `python.wasm` the runtime tests use
when no real CPython build is present. It is a hand-written WAT module, not a
compiler output, so the test suite has no toolchain dependency.

Behaviour (`argv` is ignored, exactly like a script that does not read it):

1. `fd_write` `python3-stub\n` to stdout.
2. `fd_read` stdin to EOF in 64 KiB chunks.
3. `fd_write` `stdin-bytes=` plus the byte count as eight lowercase hex digits
   and a newline.
4. `proc_exit(0)`.

The only imports are `wasi_snapshot_preview1.fd_read`, `fd_write` and
`proc_exit`, which is the part of the W7 host the wrapper and benchmark need to
exercise without a 29 MB interpreter.

`stub-python.wat` is the source. It was assembled with wasmtime's Python
bindings at authoring time (`wasmtime.wat2wasm`); wasmtime is not a repository
or test dependency. Rebuild with any WAT assembler, for example:

```sh
python3 -c 'import wasmtime; open("stub-python.wasm","wb").write(wasmtime.wat2wasm(open("stub-python.wat","rb").read()))'
```

The real artifact is not stored here: run `../build.sh` and point
`PDSH_PYTHON_WASM` at the produced `python.wasm`.

`write-many.wasm` is the WASI client the G2-FIX-61 persistence regression runs
at the `python3` program name. It imports only `wasi_snapshot_preview1`, writes
`<count>` files under `<dir>` and (with the `:trap` suffix) aborts the instance
the way a crashing interpreter does:

```
python3 -c '<count>:<dir>'          # write and exit 0
python3 -c '<count>:<dir>:trap'     # write, then trap (exit 134)
```

Paths resolve from `PWD` like the CPython cwd shim, so a relative `<dir>` is
the shell's cwd. `write-many.rs` is the source. It was compiled at authoring
time with the Rust `wasm32-wasip1` target; rustc is not a repository or test
dependency. Rebuild with:

```sh
rustc --target wasm32-wasip1 -C opt-level=z -C panic=abort -C strip=symbols \
  -C lto -o write-many.wasm write-many.rs
```
