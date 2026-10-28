;; SPDX-License-Identifier: MIT
;; fd-echo: exercises fd_read, fd_write and path_open through the VFS proxy.
;; args: fd-echo <input-name> <output-name>   (relative to the /workspace preopen)
;; argv[1] == "spin" loops forever (cancel test) and "grow" grows memory (ceiling test).
(module
  (import "wasi_snapshot_preview1" "args_sizes_get" (func $args_sizes_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "args_get" (func $args_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_read" (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_close" (func $fd_close (param i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_open" (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))

  (memory (export "memory") 2)
  (data (i32.const 320) "echo:")
  (data (i32.const 325) "[")
  (data (i32.const 326) "] ")
  (data (i32.const 328) "\n")
  (data (i32.const 9240) "fd-echo: error\n")

  (func $strlen (param $p i32) (result i32)
    (local $n i32)
    (block $done
      (loop $scan
        (br_if $done (i32.eqz (i32.load8_u (i32.add (local.get $p) (local.get $n)))))
        (local.set $n (i32.add (local.get $n) (i32.const 1)))
        (br $scan)))
    (local.get $n))

  (func $fail (param $code i32)
    (i32.store (i32.const 256) (i32.const 9240))
    (i32.store (i32.const 260) (i32.const 15))
    (drop (call $fd_write (i32.const 2) (i32.const 256) (i32.const 1) (i32.const 400)))
    (call $proc_exit (local.get $code)))

  (func (export "_start")
    (local $err i32) (local $nread i32)

    (local.set $err (call $args_sizes_get (i32.const 0) (i32.const 4)))
    (if (i32.ne (local.get $err) (i32.const 0)) (then (call $fail (i32.const 3))))
    (if (i32.ne (i32.load (i32.const 0)) (i32.const 3)) (then (call $fail (i32.const 2))))
    (local.set $err (call $args_get (i32.const 8) (i32.const 64)))
    (if (i32.ne (local.get $err) (i32.const 0)) (then (call $fail (i32.const 3))))

    (if (i32.and
          (i32.eq (call $strlen (i32.load (i32.const 12))) (i32.const 4))
          (i32.eq (i32.load (i32.load (i32.const 12))) (i32.const 0x6e697073)))
      (then (loop $spin (br $spin))))

    (if (i32.and
          (i32.eq (call $strlen (i32.load (i32.const 12))) (i32.const 4))
          (i32.eq (i32.load (i32.load (i32.const 12))) (i32.const 0x776f7267)))
      (then
        (drop (memory.grow (i32.const 200)))
        (i32.store (i32.const 256) (i32.const 325))
        (i32.store (i32.const 260) (i32.const 1))
        (drop (call $fd_write (i32.const 1) (i32.const 256) (i32.const 1) (i32.const 400)))
        (call $proc_exit (i32.const 0))))

    (local.set $err
      (call $path_open
        (i32.const 3) (i32.const 0)
        (i32.load (i32.const 12)) (call $strlen (i32.load (i32.const 12)))
        (i32.const 0) (i64.const 2) (i64.const 0) (i32.const 0)
        (i32.const 404)))
    (if (i32.ne (local.get $err) (i32.const 0)) (then (call $fail (i32.const 4))))

    (i32.store (i32.const 256) (i32.const 1024))
    (i32.store (i32.const 260) (i32.const 8192))
    (local.set $err (call $fd_read (i32.load (i32.const 404)) (i32.const 256) (i32.const 1) (i32.const 400)))
    (if (i32.ne (local.get $err) (i32.const 0)) (then (call $fail (i32.const 5))))
    (local.set $nread (i32.load (i32.const 400)))
    (drop (call $fd_close (i32.load (i32.const 404))))

    (local.set $err
      (call $path_open
        (i32.const 3) (i32.const 0)
        (i32.load (i32.const 16)) (call $strlen (i32.load (i32.const 16)))
        (i32.const 9) (i64.const 64) (i64.const 0) (i32.const 0)
        (i32.const 408)))
    (if (i32.ne (local.get $err) (i32.const 0)) (then (call $fail (i32.const 6))))

    (i32.store (i32.const 256) (i32.const 320))
    (i32.store (i32.const 260) (i32.const 5))
    (i32.store (i32.const 264) (i32.const 1024))
    (i32.store (i32.const 268) (local.get $nread))
    (local.set $err (call $fd_write (i32.load (i32.const 408)) (i32.const 256) (i32.const 2) (i32.const 400)))
    (if (i32.ne (local.get $err) (i32.const 0)) (then (call $fail (i32.const 7))))
    (drop (call $fd_close (i32.load (i32.const 408))))

    (i32.store (i32.const 256) (i32.const 325))
    (i32.store (i32.const 260) (i32.const 1))
    (i32.store (i32.const 264) (i32.load (i32.const 12)))
    (i32.store (i32.const 268) (call $strlen (i32.load (i32.const 12))))
    (i32.store (i32.const 272) (i32.const 326))
    (i32.store (i32.const 276) (i32.const 2))
    (i32.store (i32.const 280) (i32.const 1024))
    (i32.store (i32.const 284) (local.get $nread))
    (i32.store (i32.const 288) (i32.const 328))
    (i32.store (i32.const 292) (i32.const 1))
    (local.set $err (call $fd_write (i32.const 1) (i32.const 256) (i32.const 5) (i32.const 400)))
    (if (i32.ne (local.get $err) (i32.const 0)) (then (call $fail (i32.const 8))))

    (call $proc_exit (i32.const 0))))
