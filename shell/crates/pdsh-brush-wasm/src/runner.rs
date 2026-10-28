// SPDX-License-Identifier: MIT
//! A brush shell instance, its captured standard streams and its run loop.
//!
//! Everything the Worker needs from the spike is here: build a bash-compatible
//! shell with a host command table, run one script and return
//! `(exit_code, stdout, stderr)`. The C ABI in [`crate::abi`] is a thin wrapper
//! over this type.

use std::fmt;
use std::io::{Cursor, Read, Write};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex;

use brush_core::openfiles::{OpenFile, Stream};
use brush_core::{ExecutionParameters, Shell, ShellVariable, SourceInfo, extensions};

use crate::config::ShellConfig;
use crate::dispatch::{self, Dispatch, DISPATCH_VAR};

/// Maximum bytes captured per stream before the sink drops the rest.
pub const MAX_CAPTURE_BYTES: usize = 4 * 1024 * 1024;

/// A shell that could not be built or a script that could not run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunnerError(pub String);

impl fmt::Display for RunnerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for RunnerError {}

/// The observable result of one script.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RunOutcome {
    /// Exit status of the last command, in `0..=255`.
    pub exit_code: i32,
    /// Everything written to standard output.
    pub stdout: Vec<u8>,
    /// Everything written to standard error, including shell diagnostics.
    pub stderr: Vec<u8>,
    /// True when the shell ran a multi-command pipeline through the
    /// staged-buffer workaround for the missing WASI pipes.
    pub pipeline_shim: bool,
}

/// A built shell plus its current-thread runtime.
pub struct ShellRunner {
    runtime: tokio::runtime::Runtime,
    shell: Shell<extensions::DefaultShellExtensions>,
    dispatch_id: u64,
    config: ShellConfig,
}

impl fmt::Debug for ShellRunner {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ShellRunner")
            .field("dispatch_id", &self.dispatch_id)
            .field("working_dir", &self.config.working_dir)
            .finish_non_exhaustive()
    }
}

impl ShellRunner {
    /// Builds a shell with the default [`ShellConfig`].
    pub fn new(dispatch: Arc<dyn Dispatch>) -> Result<Self, RunnerError> {
        Self::with_config(dispatch, ShellConfig::default())
    }

    /// Builds a shell with an explicit configuration.
    pub fn with_config(
        dispatch: Arc<dyn Dispatch>,
        config: ShellConfig,
    ) -> Result<Self, RunnerError> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .map_err(|error| RunnerError(format!("cannot build the tokio runtime: {error}")))?;
        let dispatch_id = dispatch::install(dispatch.clone());

        let mut command_builtins =
            brush_builtins::default_builtins(brush_builtins::BuiltinSet::BashMode);
        dispatch::register_commands(&mut command_builtins, dispatch.as_ref());

        let mut builder = Shell::builder()
            .builtins(command_builtins)
            .do_not_inherit_env(true)
            .working_dir(config.working_dir.clone());

        for (name, value) in config.environment() {
            builder = builder.var(name, exported_variable(value));
        }
        builder = builder.var(DISPATCH_VAR, ShellVariable::new(dispatch_id.to_string()));

        let shell = runtime
            .block_on(builder.build())
            .map_err(|error| RunnerError(format!("cannot build the brush shell: {error:#}")))?;

        Ok(Self {
            runtime,
            shell,
            dispatch_id,
            config,
        })
    }

    /// The registry id of this shell's dispatch table.
    #[must_use]
    pub fn dispatch_id(&self) -> u64 {
        self.dispatch_id
    }

    /// The configured guest working directory.
    #[must_use]
    pub fn working_dir(&self) -> PathBuf {
        self.config.working_dir.clone()
    }

    /// Runs one script with empty standard input.
    pub fn run(&mut self, script: &str) -> Result<RunOutcome, RunnerError> {
        self.run_with_input(script, &[])
    }

    /// Runs one script with the given standard input bytes.
    pub fn run_with_input(
        &mut self,
        script: &str,
        stdin: &[u8],
    ) -> Result<RunOutcome, RunnerError> {
        match self.pipeline_stages(script) {
            Some(plan) => self.run_plan(&plan),
            None => self.run_one(script, stdin),
        }
    }

    fn run_one(&mut self, script: &str, stdin: &[u8]) -> Result<RunOutcome, RunnerError> {
        let stdout = Arc::new(Mutex::new(Vec::new()));
        let stderr = Arc::new(Mutex::new(Vec::new()));

        let mut params = self.shell.default_exec_params();
        params.set_fd(
            0,
            if stdin.is_empty() {
                OpenFile::Stream(Box::new(EmptyStream))
            } else {
                OpenFile::Stream(Box::new(InputOnlyStream::new(stdin.to_vec())))
            },
        );
        params.set_fd(
            1,
            OpenFile::Stream(Box::new(CaptureStream::new(stdout.clone()))),
        );
        params.set_fd(
            2,
            OpenFile::Stream(Box::new(CaptureStream::new(stderr.clone()))),
        );

        let exit_code = self.run_script(script, &params)?;
        Ok(RunOutcome {
            exit_code,
            stdout: take_capture(&stdout),
            stderr: take_capture(&stderr),
            pipeline_shim: false,
        })
    }

    fn run_script(
        &mut self,
        script: &str,
        params: &ExecutionParameters,
    ) -> Result<i32, RunnerError> {
        let source = SourceInfo::default();
        let result = self
            .runtime
            .block_on(self.shell.run_string(script.to_string(), &source, params))
            .map_err(|error| RunnerError(format!("{error:#}")))?;
        Ok(i32::from(u8::from(result.exit_code)))
    }

    /// Executes the stages of a top-level pipeline with in-memory buffers.
    ///
    /// brush-core 0.5.0 calls `std::io::pipe()` in its pipeline path; Rust's
    /// WASI standard library returns `Unsupported` for that call, so a plain
    /// `run_string` cannot execute `a | b` on wasm32-wasip1. The stages are
    /// run one after another and the standard output of one stage is handed to
    /// the next as standard input. brush itself also runs pipeline stages one
    /// after another on this target, so the observable result of a simple
    /// pipeline is preserved. `pipefail`, `time` and pipelines nested inside
    /// compound commands are not handled and take the normal brush path.
    #[cfg_attr(not(target_family = "wasm"), allow(dead_code))]
    fn run_plan(
        &mut self,
        plan: &crate::pipeline::PipelinePlan,
    ) -> Result<RunOutcome, RunnerError> {
        let mut input: Vec<u8> = Vec::new();
        let mut stderr = Vec::new();
        let mut exit_code = 0;
        for stage in &plan.stages {
            let outcome = self.run_one(stage, &input)?;
            input = outcome.stdout;
            stderr.extend_from_slice(&outcome.stderr);
            exit_code = outcome.exit_code;
        }
        if plan.negate {
            exit_code = i32::from(exit_code == 0);
        }
        Ok(RunOutcome {
            exit_code,
            stdout: input,
            stderr,
            pipeline_shim: true,
        })
    }

    /// Splits a script that is exactly one top-level pipeline into its stages.
    ///
    /// Returns `None` for every other shape, which then takes the normal brush
    /// path (and fails on wasm when it contains a pipe).
    #[cfg(target_family = "wasm")]
    fn pipeline_stages(&self, script: &str) -> Option<crate::pipeline::PipelinePlan> {
        crate::pipeline::single_pipeline_stages(&self.shell, script)
    }

    #[cfg(not(target_family = "wasm"))]
    fn pipeline_stages(&self, _script: &str) -> Option<crate::pipeline::PipelinePlan> {
        None
    }
}

fn exported_variable(value: String) -> ShellVariable {
    let mut variable = ShellVariable::new(value);
    variable.export();
    variable
}

fn take_capture(buffer: &Arc<Mutex<Vec<u8>>>) -> Vec<u8> {
    let mut guard = buffer
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    std::mem::take(&mut *guard)
}

/// Standard output/error sink that keeps bytes in memory.
struct CaptureStream {
    buffer: Arc<Mutex<Vec<u8>>>,
}

impl CaptureStream {
    fn new(buffer: Arc<Mutex<Vec<u8>>>) -> Self {
        Self { buffer }
    }
}

impl Read for CaptureStream {
    fn read(&mut self, _buffer: &mut [u8]) -> std::io::Result<usize> {
        Ok(0)
    }
}

impl Write for CaptureStream {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let mut guard = self
            .buffer
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let remaining = MAX_CAPTURE_BYTES.saturating_sub(guard.len());
        let take = remaining.min(bytes.len());
        guard.extend_from_slice(&bytes[..take]);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Stream for CaptureStream {
    fn clone_box(&self) -> Box<dyn Stream> {
        Box::new(Self::new(self.buffer.clone()))
    }

    #[cfg(unix)]
    fn try_clone_to_owned(&self) -> Result<std::os::fd::OwnedFd, brush_core::Error> {
        Err(brush_core::ErrorKind::CannotConvertToNativeFd.into())
    }

    #[cfg(unix)]
    fn try_borrow_as_fd(&self) -> Result<std::os::fd::BorrowedFd<'_>, brush_core::Error> {
        Err(brush_core::ErrorKind::CannotConvertToNativeFd.into())
    }
}

/// An always-empty standard input.
struct EmptyStream;

impl Read for EmptyStream {
    fn read(&mut self, _buffer: &mut [u8]) -> std::io::Result<usize> {
        Ok(0)
    }
}

impl Write for EmptyStream {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Stream for EmptyStream {
    fn clone_box(&self) -> Box<dyn Stream> {
        Box::new(Self)
    }

    #[cfg(unix)]
    fn try_clone_to_owned(&self) -> Result<std::os::fd::OwnedFd, brush_core::Error> {
        Err(brush_core::ErrorKind::CannotConvertToNativeFd.into())
    }

    #[cfg(unix)]
    fn try_borrow_as_fd(&self) -> Result<std::os::fd::BorrowedFd<'_>, brush_core::Error> {
        Err(brush_core::ErrorKind::CannotConvertToNativeFd.into())
    }
}

/// Standard input backed by a byte buffer.
struct InputOnlyStream {
    cursor: Cursor<Vec<u8>>,
}

impl InputOnlyStream {
    fn new(bytes: Vec<u8>) -> Self {
        Self {
            cursor: Cursor::new(bytes),
        }
    }
}

impl Read for InputOnlyStream {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        self.cursor.read(buffer)
    }
}

impl Write for InputOnlyStream {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Stream for InputOnlyStream {
    fn clone_box(&self) -> Box<dyn Stream> {
        let mut clone = Self::new(self.cursor.get_ref().clone());
        clone.cursor.set_position(self.cursor.position());
        Box::new(clone)
    }

    #[cfg(unix)]
    fn try_clone_to_owned(&self) -> Result<std::os::fd::OwnedFd, brush_core::Error> {
        Err(brush_core::ErrorKind::CannotConvertToNativeFd.into())
    }

    #[cfg(unix)]
    fn try_borrow_as_fd(&self) -> Result<std::os::fd::BorrowedFd<'_>, brush_core::Error> {
        Err(brush_core::ErrorKind::CannotConvertToNativeFd.into())
    }
}
