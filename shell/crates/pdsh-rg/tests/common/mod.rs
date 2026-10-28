// SPDX-License-Identifier: MIT
//! Shared fixture and invocation helper for the `pdsh-rg` integration tests.
//!
//! Every test builds a throw-away tree under the platform temporary directory,
//! mounts it at `/dsh/workspace` and `/dsh/home`, and runs the real
//! [`pdsh_rg::run_rg`] entry point with a real [`pdsh_core::StdFsVfs`]. Nothing
//! outside the temporary directory is read or written.

#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

use pdsh_core::{CancelToken, Ctx, Limits, NullBridge, StdFsVfs};

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
            "pdsh-rg-{}-{}-{}",
            std::process::id(),
            label,
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("workspace")).unwrap();
        fs::create_dir_all(root.join("home")).unwrap();
        Fixture { root }
    }

    /// Host path of the fixture root (mount table input).
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Host path of the `/dsh/workspace` mount.
    pub fn workspace(&self) -> PathBuf {
        self.root.join("workspace")
    }

    /// Host path of the `/dsh/home` mount.
    pub fn home(&self) -> PathBuf {
        self.root.join("home")
    }

    /// Write a UTF-8 file inside the workspace, creating parent directories.
    pub fn write(&self, relative: &str, contents: &str) {
        self.write_bytes(relative, contents.as_bytes());
    }

    /// Write a binary file inside the workspace.
    pub fn write_bytes(&self, relative: &str, contents: &[u8]) {
        let path = self.workspace().join(relative);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, contents).unwrap();
    }

    /// Write a UTF-8 file inside the home mount.
    pub fn write_home(&self, relative: &str, contents: &str) {
        let path = self.home().join(relative);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, contents).unwrap();
    }

    /// Create a directory inside the workspace.
    pub fn mkdir(&self, relative: &str) {
        fs::create_dir_all(self.workspace().join(relative)).unwrap();
    }

    /// Set the modification time of a workspace file.
    pub fn set_modified(&self, relative: &str, seconds_since_epoch: u64) {
        let path = self.workspace().join(relative);
        let file = fs::OpenOptions::new().write(true).open(path).unwrap();
        let time = SystemTime::UNIX_EPOCH + Duration::from_secs(seconds_since_epoch);
        file.set_times(fs::FileTimes::new().set_modified(time))
            .unwrap();
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
    /// Exit code returned by [`pdsh_rg::run_rg`].
    pub code: i32,
    /// Captured stdout bytes (already truncated by the core sink).
    pub stdout: String,
    /// Captured stderr bytes.
    pub stderr: String,
    /// True when the stdout sink truncated.
    pub stdout_truncated: bool,
}

impl Run {
    /// Split stdout into lines, dropping the trailing empty element.
    pub fn lines(&self) -> Vec<&str> {
        let mut lines: Vec<&str> = self.stdout.split('\n').collect();
        if lines.last() == Some(&"") {
            lines.pop();
        }
        lines
    }
}

/// Run `rg` with the default limits and the given guest cwd.
pub fn run(fixture: &Fixture, cwd: &str, args: &[&str]) -> Run {
    run_with(fixture, cwd, args, Limits::default(), None)
}

/// Run `rg` with explicit limits and an optional cancel token.
pub fn run_with(
    fixture: &Fixture,
    cwd: &str,
    args: &[&str],
    limits: Limits,
    cancel: Option<CancelToken>,
) -> Run {
    let vfs = StdFsVfs::for_root(fixture.root()).unwrap();
    let bridge = NullBridge;
    let mut ctx = Ctx::new(&vfs, &bridge, cwd, limits);
    if let Some(cancel) = cancel {
        ctx = ctx.with_cancel(cancel);
    }
    let mut argv = Vec::with_capacity(args.len() + 1);
    argv.push("rg".to_string());
    argv.extend(args.iter().map(|argument| (*argument).to_string()));
    let code = pdsh_rg::run_rg(&argv, &mut ctx);
    let (stdout, stderr) = ctx.finish();
    Run {
        code,
        stdout: String::from_utf8_lossy(&stdout.data).into_owned(),
        stderr: String::from_utf8_lossy(&stderr.data).into_owned(),
        stdout_truncated: stdout.truncated,
    }
}

/// Parse one JSON line into a value.
pub fn json_line(line: &str) -> serde_json::Value {
    serde_json::from_str(line).unwrap_or_else(|error| panic!("invalid JSON line {line:?}: {error}"))
}

/// Parse every JSON line of a run.
pub fn json_lines(run: &Run) -> Vec<serde_json::Value> {
    run.lines().into_iter().map(json_line).collect()
}

/// The `match` records of a JSON run.
pub fn matches(run: &Run) -> Vec<serde_json::Value> {
    json_lines(run)
        .into_iter()
        .filter(|value| value["type"] == "match")
        .collect()
}

/// The `begin` records of a JSON run.
pub fn begins(run: &Run) -> Vec<serde_json::Value> {
    json_lines(run)
        .into_iter()
        .filter(|value| value["type"] == "begin")
        .collect()
}

/// The `end` records of a JSON run.
pub fn ends(run: &Run) -> Vec<serde_json::Value> {
    json_lines(run)
        .into_iter()
        .filter(|value| value["type"] == "end")
        .collect()
}

/// The `context` records of a JSON run.
pub fn contexts(run: &Run) -> Vec<serde_json::Value> {
    json_lines(run)
        .into_iter()
        .filter(|value| value["type"] == "context")
        .collect()
}

/// The `summary` record of a JSON run.
pub fn summary(run: &Run) -> serde_json::Value {
    let mut summaries = json_lines(run)
        .into_iter()
        .filter(|value| value["type"] == "summary")
        .collect::<Vec<_>>();
    assert_eq!(summaries.len(), 1, "expected exactly one summary record");
    summaries.pop().unwrap()
}
