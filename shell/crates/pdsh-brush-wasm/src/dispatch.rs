// SPDX-License-Identifier: MIT
//! The dispatch hook that lets the host execute external command names.
//!
//! brush-core resolves a command in this order: builtin, shell function,
//! external program. The external step is unusable in a WASI reactor because
//! `std::process::Command` has no implementation there. This module turns each
//! name the host advertises into a brush builtin: when the interpreter reaches
//! the command, the builtin calls [`Dispatch::execute`] instead of spawning a
//! process.
//!
//! A builtin registration in brush-core is a plain `fn` pointer, so it cannot
//! capture the dispatch object. Each shell instead carries a small integer in
//! the [`DISPATCH_VAR`] shell variable; the builtin reads that variable and
//! looks the object up in the process-wide registry. That keeps two shells
//! with different command tables usable in one process (the tests rely on it)
//! without a global "current dispatch" that would race.

use std::collections::HashMap;
use std::fmt;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex, OnceLock};

use brush_core::builtins::{BoxFuture, ContentOptions, ContentType, Registration};
use brush_core::{commands, error, extensions, ExecutionResult};

/// Shell variable that carries the dispatch registry id of a shell.
pub const DISPATCH_VAR: &str = "PDSH_BRUSH_DISPATCH_ID";

/// Exit code used when the host reported a failure of its own.
pub const EXIT_DISPATCH_ERROR: u8 = 126;

/// Exit code used when the host observed a cancellation.
pub const EXIT_CANCELLED: u8 = 130;

/// One external command invocation handed to the host.
#[derive(Debug)]
pub struct CommandRequest<'a> {
    /// The command name as resolved by the shell (never empty).
    pub command: &'a str,
    /// Arguments after the command name.
    pub args: &'a [String],
    /// Bytes read from the command's standard input.
    pub stdin: &'a [u8],
    /// The shell's working directory, a guest path such as `/dsh/workspace`.
    pub cwd: String,
    /// Exported environment variables, sorted by name.
    pub env: Vec<(String, String)>,
}

/// The host's answer to one [`Dispatch::execute`] call.
#[derive(Debug, Clone, Default)]
pub struct CommandResult {
    /// Process exit status, clamped to `0..=255` by the shell.
    pub exit_code: i32,
    /// Bytes written to the command's standard output.
    pub stdout: Vec<u8>,
    /// Bytes written to the command's standard error.
    pub stderr: Vec<u8>,
}

/// An error reported by the host rather than by the executed program.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DispatchError(pub String);

impl fmt::Display for DispatchError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for DispatchError {}

/// A command table living in the host (the Worker's shell-ext, or a test).
pub trait Dispatch: Send + Sync {
    /// Every external command name this host can execute.
    ///
    /// brush builtins take precedence over these registrations; a name that is
    /// also a builtin keeps its builtin behaviour, as in bash.
    fn command_names(&self) -> Vec<String>;

    /// Executes one command and returns its status and captured output.
    fn execute(&self, request: CommandRequest<'_>) -> Result<CommandResult, DispatchError>;

    /// Cooperative cancellation flag, checked before and after each command.
    fn is_cancelled(&self) -> bool {
        false
    }
}

static REGISTRY: OnceLock<Mutex<Vec<Arc<dyn Dispatch>>>> = OnceLock::new();

fn registry() -> &'static Mutex<Vec<Arc<dyn Dispatch>>> {
    REGISTRY.get_or_init(|| Mutex::new(Vec::new()))
}

/// Installs a dispatch table and returns the id a shell must carry.
///
/// Installing the same `Arc` twice returns the existing id, so resetting a
/// shell does not grow the registry.
pub fn install(dispatch: Arc<dyn Dispatch>) -> u64 {
    let mut entries = registry()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(index) = entries.iter().position(|entry| Arc::ptr_eq(entry, &dispatch)) {
        return index as u64;
    }
    entries.push(dispatch);
    // The registry never removes entries, so the index is a stable id.
    entries.len() as u64 - 1
}

/// Looks up an installed dispatch table.
pub fn lookup(id: u64) -> Option<Arc<dyn Dispatch>> {
    let entries = registry()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    entries.get(usize::try_from(id).ok()?).cloned()
}

/// Registers one builtin per advertised command name.
///
/// Names that already exist in the standard set are left alone: a shell
/// builtin (`echo`, `cd`, ...) behaves like the builtin even when the host
/// advertises a program with the same name. Returns the number of names that
/// were actually added (duplicates count once).
pub fn register_commands(
    builtins: &mut HashMap<String, Registration<extensions::DefaultShellExtensions>>,
    dispatch: &dyn Dispatch,
) -> usize {
    let mut names: Vec<String> = dispatch.command_names();
    names.sort();
    names.dedup();
    let mut added = 0;
    for name in &names {
        // A name that is already a shell builtin keeps its builtin, as in bash.
        if !builtins.contains_key(name) {
            builtins.insert(name.clone(), registration());
            added += 1;
        }
    }
    added
}

/// The brush builtin registration used by every dispatched name.
#[must_use]
pub fn registration() -> Registration<extensions::DefaultShellExtensions> {
    Registration {
        execute_func: dispatch_builtin,
        content_func: dispatch_content,
        disabled: false,
        special_builtin: false,
        declaration_builtin: false,
    }
}

fn dispatch_content(
    _name: &str,
    _content_type: ContentType,
    _options: &ContentOptions,
) -> Result<String, error::Error> {
    Ok(String::new())
}

fn dispatch_builtin(
    context: commands::ExecutionContext<'_, extensions::DefaultShellExtensions>,
    args: Vec<commands::CommandArg>,
) -> BoxFuture<'_, Result<ExecutionResult, error::Error>> {
    Box::pin(dispatch_builtin_impl(context, args))
}

async fn dispatch_builtin_impl(
    context: commands::ExecutionContext<'_, extensions::DefaultShellExtensions>,
    args: Vec<commands::CommandArg>,
) -> Result<ExecutionResult, error::Error> {
    let command = context.command_name.clone();
    let Some(dispatch) = dispatch_for_shell(context.shell) else {
        let mut stderr = context.stderr();
        let _ = writeln!(stderr, "{command}: command not found");
        return Ok(ExecutionResult::new(127));
    };

    if dispatch.is_cancelled() {
        return Ok(ExecutionResult::new(EXIT_CANCELLED));
    }

    // argv[0] is the command name; the host receives only the arguments.
    let arguments: Vec<String> = args
        .iter()
        .skip(1)
        .filter_map(|argument| match argument {
            commands::CommandArg::String(value) => Some(value.clone()),
            commands::CommandArg::Assignment(assignment) => Some(assignment.to_string()),
        })
        .collect();

    let mut stdin = Vec::new();
    let _ = context.stdin().read_to_end(&mut stdin);

    let request = CommandRequest {
        command: &command,
        args: &arguments,
        stdin: &stdin,
        cwd: context.shell.working_dir().to_string_lossy().into_owned(),
        env: exported_env(context.shell),
    };

    match dispatch.execute(request) {
        Ok(result) => {
            if !result.stdout.is_empty() {
                let _ = context.stdout().write_all(&result.stdout);
            }
            if !result.stderr.is_empty() {
                let _ = context.stderr().write_all(&result.stderr);
            }
            let code = result.exit_code.clamp(0, 255);
            Ok(ExecutionResult::new(u8::try_from(code).unwrap_or(1)))
        }
        Err(failure) => {
            let mut stderr = context.stderr();
            let _ = writeln!(stderr, "{command}: {}", failure.0);
            Ok(ExecutionResult::new(EXIT_DISPATCH_ERROR))
        }
    }
}

fn dispatch_for_shell(
    shell: &brush_core::Shell<extensions::DefaultShellExtensions>,
) -> Option<Arc<dyn Dispatch>> {
    let (_, variable) = shell.env().get(DISPATCH_VAR)?;
    if !variable.value().is_set() {
        return None;
    }
    let id = variable.value().to_cow_str(shell).parse::<u64>().ok()?;
    lookup(id)
}

fn exported_env(
    shell: &brush_core::Shell<extensions::DefaultShellExtensions>,
) -> Vec<(String, String)> {
    let mut env: Vec<(String, String)> = shell
        .env()
        .iter_exported()
        .filter(|(name, _)| name.as_str() != DISPATCH_VAR)
        .filter(|(_, variable)| variable.value().is_set())
        .map(|(name, variable)| {
            (
                name.clone(),
                variable.value().to_cow_str(shell).into_owned(),
            )
        })
        .collect();
    env.sort_by(|left, right| left.0.cmp(&right.0));
    env
}
