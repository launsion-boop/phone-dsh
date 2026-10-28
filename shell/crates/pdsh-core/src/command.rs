// SPDX-License-Identifier: MIT
//! The command interface implemented by every read-only accelerator.

use crate::ctx::Ctx;

/// Exit code used when a command observed cancellation.
pub const EXIT_CANCELLED: i32 = 130;
/// Exit code used for a command-line usage error.
pub const EXIT_USAGE: i32 = 64;
/// Exit code used for an internal command error.
pub const EXIT_INTERNAL: i32 = 70;

/// One read-only accelerator command.
///
/// Implementations must:
///
/// - never write the workspace (the [`crate::vfs::Vfs`] offers no writes);
/// - call [`Ctx::check_cancel`] at least once per processed file and at least
///   once per 64 KiB of output — using [`Ctx::emit_stdout`],
///   [`Ctx::emit_stderr`], [`Ctx::begin_file`], [`Ctx::open_read`] and
///   [`Ctx::read_file`] does this automatically;
/// - return [`EXIT_CANCELLED`] when a cancelled operation reports
///   [`crate::error::Error::Cancelled`].
pub trait Command: Send + Sync {
    /// The accelerator name; equals `argv[0]`.
    fn name(&self) -> &str;

    /// Run one invocation. `argv` includes `argv[0]` and is never empty.
    fn run(&self, argv: &[String], ctx: &mut Ctx<'_>) -> i32;
}
