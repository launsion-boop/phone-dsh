// SPDX-License-Identifier: MIT
//! The panic boundary of the JNI surface.
//!
//! A Rust panic must never cross the FFI: `run_entry` catches it with
//! `catch_unwind` and calls `throw_new(java/lang/RuntimeException, "PDSH_JNI_PANIC: ...")`.
//! This test drives the same boundary function without a JVM, so it pins the
//! **message** the JVM receives and proves the panic is caught. The Java class
//! is [`pdsh_jni::RUNTIME_EXCEPTION_CLASS`], asserted here as the exact string
//! `run_entry` throws; an end-to-end assertion of the Java exception object
//! would need a JVM, which the pure-Rust test suite does not require (the
//! Android suite's `NativeWal.panicForTestNative` is the hook for that).
//!
//! A panic in the bridge would be a bug — every WAL entry point returns a coded
//! value — but the boundary is still the last line of defence, so it is tested
//! on its own.

use pdsh_jni::wal::verify_record;
use pdsh_jni::{catch_panic, RUNTIME_EXCEPTION_CLASS};

#[test]
fn a_rust_panic_is_caught_and_rendered_as_the_runtime_exception_message() {
    let outcome = catch_panic("verifyRecord", || -> String {
        panic!("synthetic WAL panic")
    });
    let message = outcome.expect_err("a panic must not escape the boundary");
    assert_eq!(message, "PDSH_JNI_PANIC: verifyRecord: synthetic WAL panic");
    assert_eq!(RUNTIME_EXCEPTION_CLASS, "java/lang/RuntimeException");
    // Reaching this line is the proof that the process did not crash: a panic
    // across `extern "system"` would abort.
}

#[test]
fn an_owned_panic_payload_is_preserved() {
    let outcome = catch_panic("scanSegment", || {
        let detail = String::from("owned panic");
        panic!("{detail}");
    });
    assert_eq!(
        outcome.expect_err("caught"),
        "PDSH_JNI_PANIC: scanSegment: owned panic"
    );
}

#[test]
fn a_non_string_panic_payload_is_labelled() {
    let outcome = catch_panic("planRecovery", || std::panic::panic_any(42u8));
    assert_eq!(
        outcome.expect_err("caught"),
        "PDSH_JNI_PANIC: planRecovery: non-string panic payload"
    );
}

#[test]
fn malformed_record_input_returns_a_coded_object_instead_of_panicking() {
    // The boundary is not the only defence: ordinary bad input is a value.
    let output = verify_record(&[0xFF; 3]);
    assert!(
        output.starts_with(r#"{"ok":false,"code":"WAL_TRUNCATED""#),
        "{output}"
    );
}
