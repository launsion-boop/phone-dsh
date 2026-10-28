// SPDX-License-Identifier: MIT
//! Fixture and invocation helper for the `pdsh-jaq` integration tests.

#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use pdsh_core::{Ctx, Limits, NullBridge, StdFsVfs};

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// One temporary fixture tree with `workspace/` and `home/` mounts.
pub struct Fixture {
    root: PathBuf,
}

impl Fixture {
    /// Create an empty fixture with the given label.
    pub fn new(label: &str) -> Fixture {
        let mut root = std::env::temp_dir();
        root.push(format!(
            "pdsh-jaq-{}-{}-{}",
            std::process::id(),
            label,
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("workspace")).unwrap();
        fs::create_dir_all(root.join("home")).unwrap();
        Fixture { root }
    }

    /// Host path of the fixture root.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Write a file inside the workspace.
    pub fn write(&self, relative: &str, contents: &str) {
        let path = self.root.join("workspace").join(relative);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, contents).unwrap();
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// The captured outcome of one accelerator run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Run {
    /// Exit code returned by the command.
    pub code: i32,
    /// Captured stdout.
    pub stdout: String,
    /// Captured stderr.
    pub stderr: String,
    /// True when the stdout sink truncated.
    pub stdout_truncated: bool,
}

fn invoke(
    fixture: &Fixture,
    cli: &[String],
    limits: Limits,
    input: Option<&[u8]>,
) -> Run {
    let vfs = StdFsVfs::for_root(fixture.root()).unwrap();
    let bridge = NullBridge;
    let mut ctx = Ctx::new(&vfs, &bridge, "/dsh/workspace", limits);
    let mut argv = Vec::with_capacity(cli.len() + 1);
    argv.push("jaq".to_string());
    argv.extend(cli.iter().cloned());
    let code = pdsh_jaq::run_jaq_with_input(&argv, &mut ctx, input);
    let (stdout, stderr) = ctx.finish();
    Run {
        code,
        stdout: String::from_utf8_lossy(&stdout.data).into_owned(),
        stderr: String::from_utf8_lossy(&stderr.data).into_owned(),
        stdout_truncated: stdout.truncated,
    }
}

/// Run `jaq` with default limits.
pub fn run(fixture: &Fixture, cli: &[String]) -> Run {
    invoke(fixture, cli, Limits::default(), None)
}

/// Run `jaq` with explicit limits.
pub fn run_with_limits(fixture: &Fixture, cli: &[String], limits: Limits) -> Run {
    invoke(fixture, cli, limits, None)
}

/// Run `jaq` with explicit standard input.
pub fn run_input(fixture: &Fixture, cli: &[String], input: &[u8]) -> Run {
    invoke(fixture, cli, Limits::default(), Some(input))
}

/// Run `jaq` with a cancel token installed on the context.
pub fn run_with_cancel(
    fixture: &Fixture,
    cli: &[String],
    cancel: pdsh_core::CancelToken,
) -> Run {
    let vfs = StdFsVfs::for_root(fixture.root()).unwrap();
    let bridge = NullBridge;
    let mut ctx = Ctx::new(&vfs, &bridge, "/dsh/workspace", Limits::default())
        .with_cancel(cancel);
    let mut argv = Vec::with_capacity(cli.len() + 1);
    argv.push("jaq".to_string());
    argv.extend(cli.iter().cloned());
    let code = pdsh_jaq::run_jaq_with_input(&argv, &mut ctx, None);
    let (stdout, stderr) = ctx.finish();
    Run {
        code,
        stdout: String::from_utf8_lossy(&stdout.data).into_owned(),
        stderr: String::from_utf8_lossy(&stderr.data).into_owned(),
        stdout_truncated: stdout.truncated,
    }
}
