// SPDX-License-Identifier: MIT
//! Fixture and invocation helper for the `pdsh-ts` integration tests.

#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use pdsh_core::{CancelToken, Ctx, Limits, NullBridge, StdFsVfs};

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// One temporary fixture tree mounted at `/dsh/workspace`.
pub struct Fixture {
    root: PathBuf,
}

impl Fixture {
    /// Create an empty fixture with the given label.
    pub fn new(label: &str) -> Fixture {
        let mut root = std::env::temp_dir();
        root.push(format!(
            "pdsh-ts-{}-{}-{}",
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
    /// Exit code.
    pub code: i32,
    /// Captured stdout.
    pub stdout: String,
    /// Captured stderr.
    pub stderr: String,
}

/// Run `ts-parse` or `ts-query` with the default limits.
pub fn run(fixture: &Fixture, command: &str, args: &[&str]) -> Run {
    run_with(fixture, command, args, Limits::default(), None)
}

/// Run a command with explicit limits and an optional cancel token.
pub fn run_with(
    fixture: &Fixture,
    command: &str,
    args: &[&str],
    limits: Limits,
    cancel: Option<CancelToken>,
) -> Run {
    let vfs = StdFsVfs::for_root(fixture.root()).unwrap();
    let bridge = NullBridge;
    let mut ctx = Ctx::new(&vfs, &bridge, "/dsh/workspace", limits);
    if let Some(cancel) = cancel {
        ctx = ctx.with_cancel(cancel);
    }
    let mut argv = Vec::with_capacity(args.len() + 1);
    argv.push(command.to_string());
    argv.extend(args.iter().map(|argument| (*argument).to_string()));
    let code = match command {
        "ts-parse" => pdsh_ts::run_ts_parse(&argv, &mut ctx),
        "ts-query" => pdsh_ts::run_ts_query(&argv, &mut ctx),
        other => panic!("unknown command {other}"),
    };
    let (stdout, stderr) = ctx.finish();
    Run {
        code,
        stdout: String::from_utf8_lossy(&stdout.data).into_owned(),
        stderr: String::from_utf8_lossy(&stderr.data).into_owned(),
    }
}
