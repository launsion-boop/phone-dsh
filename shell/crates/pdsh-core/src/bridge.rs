// SPDX-License-Identifier: MIT
//! Host bridge for `phone` / `ctx` accelerator tool calls.
//!
//! The Rust side never talks to an MCP endpoint directly; a tool call is
//! forwarded to the host app through the FFI callback (spec/v1
//! D12). A command that needs the phone context receives the JSON result as a
//! string and parses it itself.

use crate::error::{Error, Result};

/// Forward one tool call to the host app.
pub trait HostBridge: Send + Sync {
    /// Call `name` with a JSON argument object and return the JSON result.
    ///
    /// Implementations must be safe to call from the worker thread that runs
    /// the command.
    fn call_tool(&self, name: &str, args_json: &str) -> Result<String>;
}

/// A bridge that refuses every call.
///
/// Used when the host supplied no `call_tool` callback, so `phone` and `ctx`
/// fail with a clear error instead of pretending to work.
#[derive(Debug, Default, Clone, Copy)]
pub struct NullBridge;

impl HostBridge for NullBridge {
    fn call_tool(&self, name: &str, _args_json: &str) -> Result<String> {
        Err(Error::Bridge(format!(
            "no host bridge callback for tool {name}"
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_null_bridge_fails_loudly() {
        let error = NullBridge
            .call_tool("phone", "{}")
            .expect_err("NullBridge must not succeed");
        assert!(matches!(error, Error::Bridge(_)));
        assert!(error.to_string().contains("phone"));
    }
}
