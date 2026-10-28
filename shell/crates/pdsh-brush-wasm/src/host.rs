// SPDX-License-Identifier: MIT
//! The `xl` host bridge: the only non-WASI imports of the wasm module.
//!
//! The host provides four functions in the `xl` import module:
//!
//! | import | purpose |
//! |---|---|
//! | `xl_host_list_count` | number of external command names the host implements |
//! | `xl_host_list_name` | copies name `index` into guest memory |
//! | `xl_host_exec` | exchanges one wire request for one wire response |
//! | `xl_host_cancelled` | cooperative cancellation flag |
//!
//! Everything else the module needs comes from `wasi_snapshot_preview1` and is
//! limited to the filesystem, clocks and randomness; there is no socket or
//! process import. On host builds the imports do not exist and this module
//! only provides the empty fallback so `cargo test --workspace` builds.

use std::sync::Arc;

use crate::dispatch::{CommandRequest, CommandResult, Dispatch, DispatchError};

/// Largest response the host may return.
#[cfg(all(feature = "wasm-host", target_family = "wasm"))]
pub const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;

/// First response buffer size; grows when the host returns `-needed`.
#[cfg(all(feature = "wasm-host", target_family = "wasm"))]
const INITIAL_RESPONSE_BYTES: usize = 64 * 1024;

/// Name buffer size for one command name.
#[cfg(all(feature = "wasm-host", target_family = "wasm"))]
const NAME_BUFFER_BYTES: usize = 256;

/// The dispatch implementation that talks to the Worker host.
#[cfg(all(feature = "wasm-host", target_family = "wasm"))]
pub struct WasmDispatch {
    names: Vec<String>,
}

#[cfg(all(feature = "wasm-host", target_family = "wasm"))]
impl WasmDispatch {
    /// Reads the command table once and keeps the names.
    #[must_use]
    pub fn new() -> Self {
        let count = unsafe { imp::xl_host_list_count() };
        let mut names = Vec::new();
        for index in 0..count {
            if let Some(name) = read_name(index) {
                names.push(name);
            }
        }
        Self { names }
    }
}

#[cfg(all(feature = "wasm-host", target_family = "wasm"))]
impl Default for WasmDispatch {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(all(feature = "wasm-host", target_family = "wasm"))]
fn read_name(index: u32) -> Option<String> {
    let mut buffer = vec![0u8; NAME_BUFFER_BYTES];
    let length = unsafe {
        imp::xl_host_list_name(
            index,
            buffer.as_mut_ptr(),
            u32::try_from(buffer.len()).ok()?,
        )
    };
    if length < 0 {
        buffer.resize(usize::try_from(-i64::from(length)).ok()?, 0);
        let length = unsafe {
            imp::xl_host_list_name(index, buffer.as_mut_ptr(), u32::try_from(buffer.len()).ok()?)
        };
        if length < 0 {
            return None;
        }
        buffer.truncate(usize::try_from(length).ok()?);
    } else {
        buffer.truncate(usize::try_from(length).ok()?);
    }
    String::from_utf8(buffer).ok()
}

#[cfg(all(feature = "wasm-host", target_family = "wasm"))]
impl Dispatch for WasmDispatch {
    fn command_names(&self) -> Vec<String> {
        self.names.clone()
    }

    fn execute(&self, request: CommandRequest<'_>) -> Result<CommandResult, DispatchError> {
        let encoded = crate::wire::encode_request(&request)
            .map_err(|error| DispatchError(error.to_string()))?;
        let request_length = u32::try_from(encoded.len())
            .map_err(|_| DispatchError("dispatch request is too large".to_string()))?;
        let mut capacity = INITIAL_RESPONSE_BYTES;

        loop {
            let mut response = vec![0u8; capacity];
            let response_capacity = u32::try_from(capacity)
                .map_err(|_| DispatchError("dispatch response buffer is too large".to_string()))?;
            let written = unsafe {
                imp::xl_host_exec(
                    encoded.as_ptr(),
                    request_length as u32,
                    response.as_mut_ptr(),
                    response_capacity,
                )
            };
            if written >= 0 {
                response.truncate(usize::try_from(written).unwrap_or(0));
                let decoded = crate::wire::decode_result(&response)
                    .map_err(|error| DispatchError(error.to_string()))?;
                return Ok(CommandResult {
                    exit_code: decoded.exit_code,
                    stdout: decoded.stdout,
                    stderr: decoded.stderr,
                });
            }

            let needed = usize::try_from(i64::from(written).checked_neg().unwrap_or(i64::MAX))
                .unwrap_or(usize::MAX);
            if needed <= capacity || needed > MAX_RESPONSE_BYTES {
                return Err(DispatchError(
                    "the host returned an unusable response size".to_string(),
                ));
            }
            capacity = needed;
        }
    }

    fn is_cancelled(&self) -> bool {
        unsafe { imp::xl_host_cancelled() != 0 }
    }
}

/// The dispatch used by host builds and by a wasm build with the import
/// feature disabled; it advertises no commands, so every external name is
/// reported as not found.
#[cfg(not(all(feature = "wasm-host", target_family = "wasm")))]
#[derive(Debug, Default)]
pub struct EmptyDispatch;

#[cfg(not(all(feature = "wasm-host", target_family = "wasm")))]
impl Dispatch for EmptyDispatch {
    fn command_names(&self) -> Vec<String> {
        Vec::new()
    }

    fn execute(&self, request: CommandRequest<'_>) -> Result<CommandResult, DispatchError> {
        Err(DispatchError(format!(
            "no host command table: {} is not available",
            request.command
        )))
    }
}

/// The dispatch implementation for the current target.
#[must_use]
pub fn default_dispatch() -> Arc<dyn Dispatch> {
    #[cfg(all(feature = "wasm-host", target_family = "wasm"))]
    {
        Arc::new(WasmDispatch::new())
    }
    #[cfg(not(all(feature = "wasm-host", target_family = "wasm")))]
    {
        Arc::new(EmptyDispatch)
    }
}

#[cfg(all(feature = "wasm-host", target_family = "wasm"))]
mod imp {
    #[link(wasm_import_module = "xl")]
    unsafe extern "C" {
        pub(crate) fn xl_host_list_count() -> u32;
        pub(crate) fn xl_host_list_name(index: u32, ptr: *mut u8, capacity: u32) -> i32;
        pub(crate) fn xl_host_exec(
            request: *const u8,
            request_length: u32,
            response: *mut u8,
            response_capacity: u32,
        ) -> i32;
        pub(crate) fn xl_host_cancelled() -> u32;
    }
}
