// SPDX-License-Identifier: MIT
//! The complete read-only accelerator registry of the pdsh-shell.
//!
//! [`pdsh_shell_accelerators`] returns the production [`Registry`]: `rg`, `jaq`
//! (also registered as `jq`), `ts-parse`, `ts-query`, `phone` and `ctx`, each
//! advertised to the host in the capability JSON. The C ABI crate (`pdsh-ffi`)
//! links this function; the read-only guarantee comes from the pdsh-core VFS,
//! which has no write operation at all.
//!
//! `phone` and `ctx` are host-bridge accelerators: they only work when the
//! caller supplies a `pdsh_core::HostBridge`. [`pdsh_shell_accelerators_with_bridge`]
//! therefore registers and advertises them only when a bridge is present, so a
//! capability JSON can never claim a command the caller cannot execute.
//!
//! There is no general shell here and no command that writes the workspace:
//! `bash -c` and every writing command stay in the Worker (PLAN §2.4, D12).

use pdsh_core::Registry;
use pdsh_jaq::JaqCommand;
use pdsh_phone::{CtxCommand, PhoneCommand};
use pdsh_rg::RgCommand;
use pdsh_ts::{TsParseCommand, TsQueryCommand};

/// Accelerator names that require a host tool bridge to run.
pub const HOST_BRIDGE_ACCELERATORS: [&str; 2] = ["phone", "ctx"];

/// Build the complete production accelerator registry, including the
/// host-bridge `phone` / `ctx` commands.
///
/// The registry version is the pdsh-shell version, so the capability JSON always
/// identifies the exact library the host linked.
pub fn pdsh_shell_accelerators() -> Registry {
    pdsh_shell_accelerators_with_bridge(true)
}

/// Build the production accelerator registry with or without the host-bridge
/// `phone` / `ctx` commands.
///
/// A caller that cannot answer `HostBridge::call_tool` passes `false`; the
/// capability JSON then advertises only the accelerators that caller can
/// actually execute.
pub fn pdsh_shell_accelerators_with_bridge(has_tool_bridge: bool) -> Registry {
    let mut registry = Registry::new(pdsh_core::VERSION);
    register_xz_shell_accelerators_with_bridge(&mut registry, has_tool_bridge);
    registry
}

/// Add every accelerator to an existing registry, including `phone` / `ctx`.
///
/// The C ABI crate merges this into its diagnostic registry (the unadvertised
/// `echo` / `pdsh-caps` test commands live there), while the host only sees the
/// names advertised by [`pdsh_shell_accelerators`].
pub fn register_xz_shell_accelerators(registry: &mut Registry) {
    register_xz_shell_accelerators_with_bridge(registry, true);
}

/// Add the accelerators to an existing registry, optionally including the
/// host-bridge `phone` / `ctx` commands.
pub fn register_xz_shell_accelerators_with_bridge(registry: &mut Registry, has_tool_bridge: bool) {
    registry.register_accelerator(Box::new(RgCommand));
    registry.register_accelerator(Box::new(JaqCommand::new("jaq")));
    registry.register_accelerator(Box::new(JaqCommand::new("jq")));
    registry.register_accelerator(Box::new(TsParseCommand));
    registry.register_accelerator(Box::new(TsQueryCommand));
    if has_tool_bridge {
        registry.register_accelerator(Box::new(PhoneCommand));
        registry.register_accelerator(Box::new(CtxCommand));
    }
}

/// The accelerator names advertised with a host bridge, sorted.
pub fn accelerator_names() -> Vec<String> {
    accelerator_names_with_bridge(true)
}

/// The accelerator names advertised with or without a host bridge, sorted.
pub fn accelerator_names_with_bridge(has_tool_bridge: bool) -> Vec<String> {
    pdsh_shell_accelerators_with_bridge(has_tool_bridge).accelerator_names()
}
