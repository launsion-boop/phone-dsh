// SPDX-License-Identifier: MIT
//! Built-in test commands.
//!
//! `echo` and `pdsh-caps` exercise the registry, output discipline, limits and
//! cancellation from unit tests. They are registered by
//! [`crate::registry::Registry::with_defaults`] but never advertised as
//! accelerators, so the host never forwards them.

mod caps;
mod echo;

pub use caps::CapsCommand;
pub use echo::EchoCommand;
