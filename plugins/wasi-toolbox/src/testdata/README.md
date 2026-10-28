# fd-echo — WASI preview1 test module

`fd-echo.wat` is the source of the checked-in `fd-echo.wasm` (977 bytes). It is
a hand-written WAT module, not a Rust/C build, so the test fixture has no
toolchain dependency beyond a WAT assembler at authoring time.

Behaviour (`argv = [fd-echo, <input>, <output>]`, paths relative to the
`/workspace` preopen):

1. `path_open` the input read-only (`fd_read` into memory at 1024).
2. `path_open` the output with create|truncate and `fd_write` `echo:` plus the
   input bytes.
3. `fd_write` `[<input>] <bytes>\n` to stdout.
4. `proc_exit(0)`.

`argv[1] == "spin"` loops forever (cancel test). `argv[1] == "grow"` calls
`memory.grow` and then makes one host call, so the memory ceiling test observes
the growth at an import boundary.

Rebuild with wabt (Apache-2.0, build-time only, not a repository dependency):

```sh
wat2wasm fd-echo.wat -o fd-echo.wasm
wasm-validate fd-echo.wasm
```
