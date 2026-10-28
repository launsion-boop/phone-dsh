// SPDX-License-Identifier: MIT
//! pdsh-shell core: read-only accelerators for the phone-DSH Worker.
//!
//! The native side (PLAN §2.4, D12) is a read-only accelerator set, never a
//! general shell and never a writer of the workspace. This crate provides:
//!
//! - [`mount::MountTable`]: guest `/dsh/workspace` and `/dsh/home` mapped onto
//!   host directories, with every escape rejected (typed [`error::SandboxError`]);
//! - [`vfs::Vfs`] and [`vfs::StdFsVfs`]: read-only file access only;
//! - [`cancel::CancelToken`]: shared flag plus deadline, checked by commands;
//! - [`output::OutputSink`]: bounded capture with head/tail truncation;
//! - [`limits::Limits`]: deadline, output, file-count and file-size budgets;
//! - [`command::Command`] / [`registry::Registry`]: command dispatch and the
//!   capability JSON (`accelerators`, `version`, `limits`);
//! - [`ctx::Ctx`]: the per-invocation context, including the host bridge used
//!   by `phone` and `ctx`.
//!
//! The C ABI that the Swift host links lives in the `pdsh-ffi` crate; it wraps
//! this crate and is described by `include/xzshell.h`.

pub mod bridge;
pub mod cancel;
pub mod caps;
pub mod command;
pub mod commands;
pub mod ctx;
pub mod error;
pub mod limits;
pub mod mount;
pub mod output;
pub mod registry;
pub mod vfs;

pub use bridge::{HostBridge, NullBridge};
pub use cancel::CancelToken;
pub use caps::Caps;
pub use command::{Command, EXIT_CANCELLED, EXIT_INTERNAL, EXIT_USAGE};
pub use ctx::Ctx;
pub use error::{Error, Result, SandboxError, VfsError};
pub use limits::Limits;
pub use mount::{MountSpec, MountTable, GUEST_ROOT, HOME_GUEST, WORKSPACE_GUEST};
pub use output::{Output, OutputSink};
pub use registry::Registry;
pub use vfs::{DirEntry, FileKind, Metadata, StdFsVfs, Vfs};

/// The pdsh-shell version string.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
