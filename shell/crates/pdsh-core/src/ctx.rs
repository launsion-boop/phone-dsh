// SPDX-License-Identifier: MIT
//! Per-invocation command context.
//!
//! A [`Ctx`] owns the output sinks, the cancel token, the limits and the host
//! bridge of one accelerator run. It also enforces the two rules every command
//! follows:
//!
//! - check the cancel token at least once per processed file and at least once
//!   per 64 KiB of output ([`Ctx::begin_file`], [`Ctx::emit_stdout`],
//!   [`Ctx::emit_stderr`]);
//! - never read more than `limits.max_file_bytes` from one file and never open
//!   more than `limits.max_files` files ([`Ctx::open_read`], [`Ctx::read_file`]).
//!
//! The output environment is forced to `TERM=dumb`, `NO_COLOR=1` and
//! `LANG=C.UTF-8` regardless of the request, so an accelerator never emits
//! terminal control sequences or locale-dependent text.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::bridge::HostBridge;
use crate::cancel::CancelToken;
use crate::caps::Caps;
use crate::error::{Error, Result};
use crate::limits::Limits;
use crate::output::{Output, OutputSink};
use crate::vfs::{DirEntry, Metadata, Vfs};

/// Output bytes between two mandatory cancel checks.
pub const CANCEL_CHECK_INTERVAL_BYTES: u64 = 64 * 1024;

/// Environment keys the harness forces; a request cannot override them.
pub const FORCED_ENV: [(&str, &str); 3] =
    [("TERM", "dumb"), ("NO_COLOR", "1"), ("LANG", "C.UTF-8")];

/// Execution context handed to one [`crate::command::Command`].
pub struct Ctx<'a> {
    vfs: &'a dyn Vfs,
    bridge: &'a dyn HostBridge,
    cwd: PathBuf,
    env: BTreeMap<String, String>,
    stdout: OutputSink,
    stderr: OutputSink,
    cancel: CancelToken,
    limits: Limits,
    caps: Caps,
    files_opened: usize,
    bytes_since_cancel_check: u64,
}

impl<'a> Ctx<'a> {
    /// Build a context with the forced environment and a fresh cancel token.
    pub fn new(
        vfs: &'a dyn Vfs,
        bridge: &'a dyn HostBridge,
        cwd: impl Into<PathBuf>,
        limits: Limits,
    ) -> Self {
        let mut env = BTreeMap::new();
        for (key, value) in FORCED_ENV {
            env.insert(key.to_string(), value.to_string());
        }
        let max_output_bytes = limits.max_output_bytes;
        Ctx {
            vfs,
            bridge,
            cwd: cwd.into(),
            env,
            stdout: OutputSink::new(max_output_bytes),
            stderr: OutputSink::new(max_output_bytes),
            cancel: CancelToken::new(),
            limits,
            caps: Caps::empty(env!("CARGO_PKG_VERSION")),
            files_opened: 0,
            bytes_since_cancel_check: 0,
        }
    }

    /// Install the request's cancel token.
    pub fn with_cancel(mut self, cancel: CancelToken) -> Self {
        self.cancel = cancel;
        self
    }

    /// Layer request environment variables over the forced environment.
    ///
    /// Forced keys are never replaced; an attempt to set one is ignored.
    pub fn apply_env<I, K, V>(&mut self, pairs: I)
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        for (key, value) in pairs {
            let key = key.into();
            if FORCED_ENV.iter().any(|(forced, _)| *forced == key.as_str()) {
                continue;
            }
            self.env.insert(key, value.into());
        }
    }

    /// The current guest working directory.
    pub fn cwd(&self) -> &Path {
        &self.cwd
    }

    /// Look up an environment variable.
    pub fn env_var(&self, key: &str) -> Option<&str> {
        self.env.get(key).map(String::as_str)
    }

    /// The enforced limits.
    pub fn limits(&self) -> &Limits {
        &self.limits
    }

    /// The host bridge (used by `phone` and `ctx`).
    pub fn bridge(&self) -> &dyn HostBridge {
        self.bridge
    }

    /// The cancel token.
    pub fn cancel_token(&self) -> &CancelToken {
        &self.cancel
    }

    /// Return `Err(Cancelled)` if the token fired.
    pub fn check_cancel(&self) -> Result<()> {
        self.cancel.check()
    }

    /// Number of files opened so far in this invocation.
    pub fn files_opened(&self) -> usize {
        self.files_opened
    }

    /// The capability object the registry installed for this run.
    pub fn caps(&self) -> &Caps {
        &self.caps
    }

    /// Render the capabilities JSON for this invocation.
    pub fn caps_json(&self) -> String {
        self.caps.json(&self.limits)
    }

    pub(crate) fn set_caps(&mut self, caps: Caps) {
        self.caps = caps;
    }

    /// Check cancellation and count one processed file against `max_files`.
    pub fn begin_file(&mut self) -> Result<()> {
        self.cancel.check()?;
        if self.files_opened >= self.limits.max_files {
            return Err(Error::LimitExceeded {
                limit: "max_files",
                value: u64::try_from(self.files_opened).unwrap_or(u64::MAX) + 1,
                max: u64::try_from(self.limits.max_files).unwrap_or(u64::MAX),
            });
        }
        self.files_opened += 1;
        Ok(())
    }

    /// Write bytes to stdout, checking the cancel token at least every 64 KiB.
    pub fn emit_stdout(&mut self, data: &[u8]) -> Result<()> {
        self.check_output_progress(data.len())?;
        self.stdout.write(data);
        Ok(())
    }

    /// Write a UTF-8 string to stdout.
    pub fn emit_stdout_str(&mut self, text: &str) -> Result<()> {
        self.emit_stdout(text.as_bytes())
    }

    /// Write bytes to stderr, checking the cancel token at least every 64 KiB.
    pub fn emit_stderr(&mut self, data: &[u8]) -> Result<()> {
        self.check_output_progress(data.len())?;
        self.stderr.write(data);
        Ok(())
    }

    /// Write a UTF-8 string to stderr.
    pub fn emit_stderr_str(&mut self, text: &str) -> Result<()> {
        self.emit_stderr(text.as_bytes())
    }

    fn check_output_progress(&mut self, bytes: usize) -> Result<()> {
        self.cancel.check()?;
        self.bytes_since_cancel_check = self
            .bytes_since_cancel_check
            .saturating_add(bytes as u64);
        if self.bytes_since_cancel_check >= CANCEL_CHECK_INTERVAL_BYTES {
            self.bytes_since_cancel_check = 0;
            self.cancel.check()?;
        }
        Ok(())
    }

    /// Metadata of a guest path (relative paths resolve against the cwd).
    pub fn metadata(&self, path: &Path) -> Result<Metadata> {
        let guest = self.absolute(path);
        Ok(self.vfs.metadata(&guest)?)
    }

    /// Directory entries of a guest path.
    pub fn read_dir(&self, path: &Path) -> Result<Vec<DirEntry>> {
        let guest = self.absolute(path);
        Ok(self.vfs.read_dir(&guest)?)
    }

    /// Canonical guest path of a guest path.
    pub fn canonicalize(&self, path: &Path) -> Result<PathBuf> {
        let guest = self.absolute(path);
        Ok(self.vfs.canonicalize(&guest)?)
    }

    /// Open a guest path after checking `max_file_bytes` and `max_files`.
    pub fn open_read(&mut self, path: &Path) -> Result<Box<dyn Read + Send>> {
        let guest = self.absolute(path);
        let metadata = self.vfs.metadata(&guest)?;
        self.check_file_size(metadata.len)?;
        self.begin_file()?;
        Ok(self.vfs.open_read(&guest)?)
    }

    /// Read a whole guest file, bounded by `max_file_bytes`.
    pub fn read_file(&mut self, path: &Path) -> Result<Vec<u8>> {
        let guest = self.absolute(path);
        let metadata = self.vfs.metadata(&guest)?;
        self.check_file_size(metadata.len)?;
        self.begin_file()?;
        let reader = self.vfs.open_read(&guest)?;
        let max = self.limits.max_file_bytes;
        let mut data = Vec::new();
        reader
            .take(max.saturating_add(1))
            .read_to_end(&mut data)
            .map_err(|error| Error::Vfs(crate::error::VfsError::Io {
                path: guest.display().to_string(),
                error,
            }))?;
        if data.len() as u64 > max {
            return Err(Error::LimitExceeded {
                limit: "max_file_bytes",
                value: data.len() as u64,
                max,
            });
        }
        Ok(data)
    }

    /// Consume the context and return `(stdout, stderr)`.
    pub fn finish(self) -> (Output, Output) {
        (self.stdout.finish(), self.stderr.finish())
    }

    /// A snapshot of the captured stdout without consuming the context.
    pub fn stdout_capture(&self) -> Output {
        self.stdout.capture()
    }

    /// A snapshot of the captured stderr without consuming the context.
    pub fn stderr_capture(&self) -> Output {
        self.stderr.capture()
    }

    fn absolute(&self, path: &Path) -> PathBuf {
        if path.is_absolute() {
            path.to_path_buf()
        } else {
            self.cwd.join(path)
        }
    }

    fn check_file_size(&self, len: u64) -> Result<()> {
        if len > self.limits.max_file_bytes {
            return Err(Error::LimitExceeded {
                limit: "max_file_bytes",
                value: len,
                max: self.limits.max_file_bytes,
            });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bridge::NullBridge;
    use crate::mount::tests::TestTree;
    use crate::vfs::StdFsVfs;
    use std::time::Duration;

    fn context<'a>(
        vfs: &'a StdFsVfs,
        bridge: &'a NullBridge,
        limits: Limits,
    ) -> Ctx<'a> {
        Ctx::new(vfs, bridge, PathBuf::from("/dsh/workspace"), limits)
    }

    #[test]
    fn the_forced_environment_cannot_be_overridden() {
        let tree = TestTree::new("ctx-env");
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        let bridge = NullBridge;
        let mut ctx = context(&vfs, &bridge, Limits::default());
        ctx.apply_env([
            ("TERM", "xterm-256color"),
            ("NO_COLOR", "0"),
            ("LANG", "en_US.UTF-8"),
            ("XL_IDEMPOTENCY_KEY", "xl1-abc"),
        ]);
        assert_eq!(ctx.env_var("TERM"), Some("dumb"));
        assert_eq!(ctx.env_var("NO_COLOR"), Some("1"));
        assert_eq!(ctx.env_var("LANG"), Some("C.UTF-8"));
        assert_eq!(ctx.env_var("XL_IDEMPOTENCY_KEY"), Some("xl1-abc"));
    }

    #[test]
    fn relative_paths_resolve_against_the_cwd() {
        let tree = TestTree::new("ctx-relative");
        std::fs::write(tree.workspace().join("a.txt"), b"abc").unwrap();
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        let bridge = NullBridge;
        let mut ctx = context(&vfs, &bridge, Limits::default());
        assert_eq!(ctx.read_file(Path::new("a.txt")).unwrap(), b"abc");
        assert!(ctx.metadata(Path::new("a.txt")).unwrap().is_file());
    }

    #[test]
    fn max_file_bytes_is_enforced_before_reading() {
        let tree = TestTree::new("ctx-file-limit");
        std::fs::write(tree.workspace().join("big"), vec![b'x'; 32]).unwrap();
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        let bridge = NullBridge;
        let limits = Limits::default().with_timeout_ms(0);
        let limits = Limits {
            max_file_bytes: 16,
            ..limits
        };
        let mut ctx = context(&vfs, &bridge, limits);
        match ctx.read_file(Path::new("big")) {
            Err(Error::LimitExceeded { limit, value, max }) => {
                assert_eq!(limit, "max_file_bytes");
                assert_eq!(value, 32);
                assert_eq!(max, 16);
            }
            other => panic!("expected a file-size limit error, got {other:?}"),
        }
        assert_eq!(ctx.files_opened(), 0);
    }

    #[test]
    fn max_files_is_enforced() {
        let tree = TestTree::new("ctx-file-count");
        std::fs::write(tree.workspace().join("a"), b"a").unwrap();
        std::fs::write(tree.workspace().join("b"), b"b").unwrap();
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        let bridge = NullBridge;
        let limits = Limits {
            max_files: 1,
            ..Limits::default()
        };
        let mut ctx = context(&vfs, &bridge, limits);
        assert!(ctx.open_read(Path::new("a")).is_ok());
        match ctx.open_read(Path::new("b")) {
            Err(Error::LimitExceeded { limit, .. }) => assert_eq!(limit, "max_files"),
            Err(other) => panic!("expected a file-count limit error, got {other:?}"),
            Ok(_) => panic!("expected a file-count limit error, got a reader"),
        }
        assert_eq!(ctx.files_opened(), 1);
    }

    #[test]
    fn output_is_counted_and_truncated_per_stream() {
        let tree = TestTree::new("ctx-output");
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        let bridge = NullBridge;
        let limits = Limits {
            max_output_bytes: 10,
            ..Limits::default()
        };
        let mut ctx = context(&vfs, &bridge, limits);
        ctx.emit_stdout(b"0123456789abcdef").unwrap();
        ctx.emit_stderr(b"err").unwrap();
        let stdout = ctx.stdout_capture();
        assert!(stdout.truncated);
        assert_eq!(stdout.total_bytes, 16);
        let stderr = ctx.stderr_capture();
        assert!(!stderr.truncated);
        assert_eq!(stderr.data, b"err");
    }

    #[test]
    fn a_cancelled_token_stops_output() {
        let tree = TestTree::new("ctx-cancel");
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        let bridge = NullBridge;
        let token = CancelToken::with_timeout(Duration::from_secs(60));
        let mut ctx = context(&vfs, &bridge, Limits::default()).with_cancel(token.clone());
        token.cancel();
        assert!(matches!(ctx.emit_stdout(b"x"), Err(Error::Cancelled)));
        assert!(matches!(ctx.begin_file(), Err(Error::Cancelled)));
    }

    #[test]
    fn caps_json_uses_the_installed_caps_and_limits() {
        let tree = TestTree::new("ctx-caps");
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        let bridge = NullBridge;
        let mut ctx = context(&vfs, &bridge, Limits::default());
        ctx.set_caps(Caps::new(["rg"], "9.9.9"));
        let json = ctx.caps_json();
        assert!(json.contains("\"rg\""));
        assert!(json.contains("\"9.9.9\""));
        assert!(json.contains("\"max_file_bytes\""));
    }
}
