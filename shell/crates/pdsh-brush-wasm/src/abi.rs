// SPDX-License-Identifier: MIT
//! C ABI used by the Node harness (and later by a Worker WASI host).
//!
//! The guest is a WASI *reactor*: the host calls the functions below through
//! `WebAssembly.Instance.exports` after `wasi.initialize()`. Buffers never
//! cross the boundary implicitly: the host allocates with
//! [`xl_brush_alloc`], writes the script, calls [`xl_brush_run`], and reads the
//! captured streams with [`xl_brush_stdout`] and [`xl_brush_stderr`].
//!
//! Return conventions:
//!
//! | function | success | failure |
//! |---|---|---|
//! | `xl_brush_init` / `xl_brush_reset` | `0` | `70`, message in the error buffer |
//! | `xl_brush_run` | the shell exit status | `70` for a shell-level failure |
//! | `xl_brush_stdout` / `stderr` / `error` | total byte length | `-1` |
//! | `xl_brush_version` | total byte length | `-1` |

use std::cell::RefCell;
use std::ffi::c_void;

use std::sync::Arc;

use crate::config::ShellConfig;
use crate::dispatch::Dispatch;
use crate::host;
use crate::runner::{RunOutcome, RunnerError, ShellRunner};

/// Exit code returned for a shell-level failure (sysexits `EX_SOFTWARE`).
pub const EXIT_INTERNAL: i32 = 70;

#[derive(Default)]
struct AbiState {
    dispatch: Option<Arc<dyn Dispatch>>,
    runner: Option<ShellRunner>,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    error: Vec<u8>,
    pipeline_shim: bool,
}

thread_local! {
    static STATE: RefCell<AbiState> = const { RefCell::new(AbiState::new()) };
}

impl AbiState {
    const fn new() -> Self {
        Self {
            dispatch: None,
            runner: None,
            stdout: Vec::new(),
            stderr: Vec::new(),
            error: Vec::new(),
            pipeline_shim: false,
        }
    }

    fn ensure_runner(&mut self) -> Result<(), RunnerError> {
        if self.runner.is_none() {
            let dispatch = self
                .dispatch
                .get_or_insert_with(host::default_dispatch)
                .clone();
            self.runner = Some(ShellRunner::with_config(dispatch, ShellConfig::default())?);
        }
        Ok(())
    }

    fn fail(&mut self, message: &str) -> i32 {
        self.error = message.as_bytes().to_vec();
        EXIT_INTERNAL
    }
}

fn with_state<T>(function: impl FnOnce(&mut AbiState) -> T) -> T {
    STATE.with(|cell| function(&mut cell.borrow_mut()))
}

/// Allocates `length` bytes of guest memory for the host.
///
/// # Safety
/// The caller must release the pointer with [`xl_brush_free`] and must not use
/// it after that call. The allocator is not required to zero the memory.
#[no_mangle]
pub unsafe extern "C" fn xl_brush_alloc(length: u32) -> *mut u8 {
    let mut buffer = Vec::<u8>::with_capacity(length as usize);
    let pointer = buffer.as_mut_ptr();
    std::mem::forget(buffer);
    pointer
}

/// Releases a buffer returned by [`xl_brush_alloc`].
///
/// # Safety
/// `pointer` must come from [`xl_brush_alloc`] with the same `length`, and it
/// must not have been released before.
#[no_mangle]
pub unsafe extern "C" fn xl_brush_free(pointer: *mut u8, length: u32) {
    if pointer.is_null() {
        return;
    }
    drop(Vec::from_raw_parts(pointer, 0, length as usize));
}

/// Creates the shell. Idempotent; called implicitly by [`xl_brush_run`].
#[no_mangle]
pub extern "C" fn xl_brush_init() -> i32 {
    with_state(|state| match state.ensure_runner() {
        Ok(()) => 0,
        Err(error) => state.fail(&error.to_string()),
    })
}

/// Drops the shell and its state, then creates a fresh one.
#[no_mangle]
pub extern "C" fn xl_brush_reset() -> i32 {
    with_state(|state| {
        state.runner = None;
        state.stdout.clear();
        state.stderr.clear();
        state.error.clear();
        state.pipeline_shim = false;
        match state.ensure_runner() {
            Ok(()) => 0,
            Err(error) => state.fail(&error.to_string()),
        }
    })
}

/// Runs one shell script.
///
/// # Safety
/// `script` must point to `length` initialized bytes owned by the caller.
#[no_mangle]
pub unsafe extern "C" fn xl_brush_run(script: *const u8, length: u32) -> i32 {
    if script.is_null() && length != 0 {
        return with_state(|state| state.fail("null script pointer"));
    }
    let bytes: &[u8] = if length == 0 {
        &[]
    } else {
        // SAFETY: the caller promises `length` initialized bytes at `script`.
        unsafe { std::slice::from_raw_parts(script, length as usize) }
    };
    let Ok(source) = std::str::from_utf8(bytes) else {
        return with_state(|state| state.fail("script is not valid UTF-8"));
    };
    let source = source.to_string();

    with_state(|state| {
        state.stdout.clear();
        state.stderr.clear();
        state.error.clear();
        state.pipeline_shim = false;
        if let Err(error) = state.ensure_runner() {
            return state.fail(&error.to_string());
        }
        let Some(runner) = state.runner.as_mut() else {
            return state.fail("shell is not initialized");
        };
        match runner.run(&source) {
            Ok(RunOutcome {
                exit_code,
                stdout,
                stderr,
                pipeline_shim,
            }) => {
                state.stdout = stdout;
                state.stderr = stderr;
                state.pipeline_shim = pipeline_shim;
                exit_code
            }
            Err(error) => state.fail(&error.to_string()),
        }
    })
}

fn copy_out(bytes: &[u8], pointer: *mut c_void, capacity: u32) -> i32 {
    if pointer.is_null() {
        return i32::try_from(bytes.len()).unwrap_or(i32::MAX);
    }
    let capacity = capacity as usize;
    let take = capacity.min(bytes.len());
    if take > 0 {
        // SAFETY: the caller promises capacity writable bytes at the pointer.
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), pointer.cast::<u8>(), take) };
    }
    i32::try_from(bytes.len()).unwrap_or(i32::MAX)
}

/// Copies the last run's standard output, returning its total length.
///
/// # Safety
/// `pointer` must be writable for `capacity` bytes.
#[no_mangle]
pub unsafe extern "C" fn xl_brush_stdout(pointer: *mut c_void, capacity: u32) -> i32 {
    with_state(|state| copy_out(&state.stdout, pointer, capacity))
}

/// Copies the last run's standard error, returning its total length.
///
/// # Safety
/// `pointer` must be writable for `capacity` bytes.
#[no_mangle]
pub unsafe extern "C" fn xl_brush_stderr(pointer: *mut c_void, capacity: u32) -> i32 {
    with_state(|state| copy_out(&state.stderr, pointer, capacity))
}

/// Copies the last shell-level error, returning its total length.
///
/// # Safety
/// `pointer` must be writable for `capacity` bytes.
#[no_mangle]
pub unsafe extern "C" fn xl_brush_error(pointer: *mut c_void, capacity: u32) -> i32 {
    with_state(|state| copy_out(&state.error, pointer, capacity))
}

/// Copies the crate version, returning its total length.
///
/// # Safety
/// `pointer` must be writable for `capacity` bytes.
#[no_mangle]
pub unsafe extern "C" fn xl_brush_version(pointer: *mut c_void, capacity: u32) -> i32 {
    copy_out(crate::VERSION.as_bytes(), pointer, capacity)
}

/// Returns `1` when the last run executed a top-level pipeline through the
/// WASI file-redirection workaround, `0` otherwise.
#[no_mangle]
pub extern "C" fn xl_brush_pipeline_shim() -> u32 {
    with_state(|state| u32::from(state.pipeline_shim))
}
