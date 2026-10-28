// SPDX-License-Identifier: MIT
//! `pdsh-caps`: print the capability JSON of the current registry.

use crate::command::{Command, EXIT_CANCELLED};
use crate::ctx::Ctx;

/// Prints `{"accelerators":[...],"version":...,"limits":{...}}`.
#[derive(Debug, Default, Clone, Copy)]
pub struct CapsCommand;

impl CapsCommand {
    /// Create the command.
    pub fn new() -> Self {
        CapsCommand
    }
}

impl Command for CapsCommand {
    fn name(&self) -> &str {
        "pdsh-caps"
    }

    fn run(&self, _argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
        let mut json = ctx.caps_json();
        json.push('\n');
        match ctx.emit_stdout_str(&json) {
            Ok(()) => 0,
            Err(_) => EXIT_CANCELLED,
        }
    }
}
