// SPDX-License-Identifier: MIT
//! Wasm brush spike: can the Rust brush shell be the Worker's bash core?
//!
//! The crate wraps the MIT `brush-core` crate in a WASI reactor that:
//!
//! - builds a bash-compatible shell with the standard builtins;
//! - routes every external command name the host advertises to an imported
//!   host function instead of `std::process::Command` (WASI has no processes);
//! - restricts the guest to the WASI filesystem, clocks and randomness, with
//!   no network or process imports;
//! - exposes a small C ABI (`abi`) that a Node harness or a Worker WASI host
//!   drives.
//!
//! The feasibility report, including the measured sizes and corpus coverage,
//! is `REPORT.md` next to this crate. The module is optional: it is not part of
//! `pdsh-all` and nothing in the native accelerators depends on it.
//!
//! Two brush-core 0.5.0 facts drive the shape of this crate:
//!
//! 1. There is no public external-command hook. The host command table is
//!    therefore installed as brush *builtins*; builtins take precedence over
//!    functions and external programs, exactly like bash's own builtins.
//! 2. `std::io::pipe` is unsupported on wasm32-wasip1, and brush-core 0.5.0
//!    calls it directly in its pipeline and command-substitution paths. A
//!    top-level pipeline is therefore executed stage by stage through files in
//!    `/dsh/tmp` ([`pipeline`]); everything else fails as it does in the
//!    released crate. See `REPORT.md` for the upstream status.

#![deny(missing_docs)]

pub mod abi;
pub mod config;
pub mod dispatch;
pub mod host;
pub mod pipeline;
pub mod runner;
pub mod wire;

pub use config::ShellConfig;
pub use dispatch::{CommandRequest, CommandResult, Dispatch, DispatchError};
pub use runner::{RunOutcome, RunnerError, ShellRunner};

/// The crate version.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
