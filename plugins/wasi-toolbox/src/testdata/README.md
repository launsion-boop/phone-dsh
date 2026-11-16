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

# fd-patch — back-patching WASI test module

`fd-patch.c` is the source of the checked-in `fd-patch.wasm` (9795 bytes,
sha256 `f76ebded77418d28e9dba0d90ebdf9ff722f79797b5cecce4c1a884d93893697`).
`argv = [fd-patch, <path>]`: it creates the file, writes `AAAAAAAA`, seeks to 2
and writes `bb`, seeks to END and writes `cc`, seeks to 12 and writes `d`, then
closes without `fsync`. The file must end as `AAbbAAAAcc\0\0d`. It is the
smallest guest that makes positional writes, which `fd-echo` cannot.

Rebuild with WASI SDK 29 (Apache-2.0 WITH LLVM-exception, build-time only):

```sh
$WASI_SDK/bin/clang --target=wasm32-wasip1 --sysroot=$WASI_SDK/share/wasi-sysroot \
  -Os -Wl,--strip-all -o fd-patch.wasm fd-patch.c
```
