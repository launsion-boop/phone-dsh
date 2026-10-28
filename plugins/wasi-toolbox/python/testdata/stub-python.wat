;; SPDX-License-Identifier: MIT
;; stub-python: the stand-in `python.wasm` used by the runtime tests when no
;; real CPython build is present. It speaks only WASI preview1 stdio: it writes
;; a fixed marker, drains stdin and prints the number of bytes it read as eight
;; lowercase hex digits, so the tests can prove the wrapper launched a WASI
;; instance and that the benchmark fed its JSON document through stdin.
;;
;; It deliberately imports nothing outside `wasi_snapshot_preview1`, the same
;; namespace the real CPython build imports.
(module
  (import "wasi_snapshot_preview1" "fd_read"
    (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))

  (memory (export "memory") 4)
  ;; 1024: marker; 1040: prefix; 1052: newline; 1100: hex digits.
  (data (i32.const 1024) "python3-stub\n")
  (data (i32.const 1040) "stdin-bytes=")
  (data (i32.const 1052) "\n")
  (data (i32.const 1100) "0123456789abcdef")

  (func $write_all (param $ptr i32) (param $len i32)
    (i32.store (i32.const 0) (local.get $ptr))
    (i32.store (i32.const 4) (local.get $len))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 16))))

  (func (export "_start")
    (local $total i32)
    (local $nread i32)
    (local $shift i32)
    (local $nibble i32)

    ;; Marker line: tells the test the stub instance really ran.
    (call $write_all (i32.const 1024) (i32.const 13))

    ;; Drain stdin in 64 KiB chunks (buffer at 4096, iovec at 8, result at 20).
    (block $done
      (loop $read
        (i32.store (i32.const 8) (i32.const 4096))
        (i32.store (i32.const 12) (i32.const 65536))
        (local.set $nread
          (call $fd_read (i32.const 0) (i32.const 8) (i32.const 1) (i32.const 20)))
        (if (i32.ne (local.get $nread) (i32.const 0)) (then (call $proc_exit (i32.const 9))))
        (local.set $nread (i32.load (i32.const 20)))
        (if (i32.eqz (local.get $nread)) (then (br $done)))
        (local.set $total (i32.add (local.get $total) (local.get $nread)))
        (br $read)))

    ;; "stdin-bytes="
    (call $write_all (i32.const 1040) (i32.const 12))

    ;; Format the total as eight hex digits, most significant first.
    (local.set $shift (i32.const 28))
    (block $hex_done
      (loop $hex
        (local.set $nibble
          (i32.and
            (i32.shr_u (local.get $total) (local.get $shift))
            (i32.const 15)))
        (i32.store8
          (i32.add (i32.const 2000) (i32.div_u (i32.sub (i32.const 28) (local.get $shift)) (i32.const 4)))
          (i32.load8_u (i32.add (i32.const 1100) (local.get $nibble))))
        (if (i32.eqz (local.get $shift)) (then (br $hex_done)))
        (local.set $shift (i32.sub (local.get $shift) (i32.const 4)))
        (br $hex)))
    (call $write_all (i32.const 2000) (i32.const 8))
    (call $write_all (i32.const 1052) (i32.const 1))

    (call $proc_exit (i32.const 0))))
