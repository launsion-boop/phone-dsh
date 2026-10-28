// SPDX-License-Identifier: MIT
//! Host-side tests for the C ABI the Node harness and a Worker host call.
//!
//! These exercise the reactor entry points directly (the thread-local state
//! makes each test thread independent). The real wasm instantiation is covered
//! by `harness/smoke.mjs`.

use pdsh_brush_wasm::abi::{
    xl_brush_alloc, xl_brush_error, xl_brush_free, xl_brush_init, xl_brush_reset, xl_brush_run,
    xl_brush_stdout,
};

/// Run a script through the ABI and return `(exit_code, stdout)`.
fn run(script: &str) -> (i32, String) {
    assert_eq!(xl_brush_init(), 0, "shell initializes");
    let bytes = script.as_bytes();
    // SAFETY: the pointer comes from the guest allocator and is released below.
    unsafe {
        let pointer = xl_brush_alloc(u32::try_from(bytes.len()).expect("length"));
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), pointer, bytes.len());
        let exit_code = xl_brush_run(pointer, u32::try_from(bytes.len()).expect("length"));
        xl_brush_free(pointer, u32::try_from(bytes.len()).expect("length"));
        let length = xl_brush_stdout(std::ptr::null_mut(), 0);
        assert!(length >= 0, "stdout length");
        let mut output = vec![0u8; usize::try_from(length).expect("length")];
        xl_brush_stdout(
            output.as_mut_ptr().cast(),
            u32::try_from(output.len()).expect("length"),
        );
        (exit_code, String::from_utf8(output).expect("utf-8"))
    }
}

#[test]
fn abi_runs_a_script_and_copies_stdout() {
    let (exit_code, stdout) = run("for i in 1 2; do echo \"n=$i\"; done");
    assert_eq!(exit_code, 0);
    assert_eq!(stdout, "n=1\nn=2\n");
}

#[test]
fn abi_reports_a_non_utf8_script() {
    assert_eq!(xl_brush_init(), 0);
    let bytes = [0xff_u8, 0xfe];
    // SAFETY: the buffer is allocated and freed by the guest allocator.
    unsafe {
        let pointer = xl_brush_alloc(2);
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), pointer, bytes.len());
        let exit_code = xl_brush_run(pointer, 2);
        xl_brush_free(pointer, 2);
        assert_eq!(exit_code, 70);
        let length = xl_brush_error(std::ptr::null_mut(), 0);
        assert!(length > 0, "an error message is available");
    }
}

#[test]
fn abi_reset_drops_shell_state() {
    let (_, first) = run("GREETING=hello; echo \"$GREETING\"");
    assert_eq!(first, "hello\n");
    assert_eq!(xl_brush_reset(), 0);
    let (_, second) = run("echo \"${GREETING:-unset}\"");
    assert_eq!(second, "unset\n");
}
