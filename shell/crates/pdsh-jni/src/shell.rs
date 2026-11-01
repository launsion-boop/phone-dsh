// SPDX-License-Identifier: MIT
//! Thin JNI-side bridge to the `pdsh-ffi` unified C ABI.
//!
//! `pdsh-ffi` (declared in `shell/include/xzshell.h`) is the one entry point of
//! the read-only accelerator registry: `pdsh_run` takes an `XzRequest` whose
//! `argv[0]` selects the accelerator, and `pdsh_caps_json_with_bridge` reports
//! what the linked registry can actually run. This module therefore adds no
//! accelerator logic, no registry and no argv parser of its own. It
//!
//! 1. validates the arguments a JNI caller can get wrong (C strings and NUL,
//!    an empty `argv`, a relative guest `cwd`, no mounts, a negative limit),
//! 2. builds the C request and the two output callbacks,
//! 3. joins the `pdsh-ffi` worker before returning, so one JNI call is one
//!    completed run (the FFI's own handle table never leaks into Kotlin), and
//! 4. frames the exit code and the two captured streams for the Kotlin binding.
//!
//! The frame is deliberately binary rather than base64-in-JSON: a stream is
//! already bounded by `max_output_bytes`, and the Kotlin side needs the bytes,
//! not an encoding of them.
//!
//! ```text
//! offset 0  4 bytes  exit code, big-endian i32
//! offset 4  4 bytes  stdout length, big-endian u32
//! offset 8  N bytes  stdout
//! offset 8+N         stderr (the rest of the frame)
//! ```
//!
//! The two output streams are the ones the FFI already truncated to
//! `max_output_bytes` each (`pdsh_core::OutputSink`), so this module never sees
//! unbounded output.
//!
//! No host tool bridge is supplied: `call_tool` is `None`, so the FFI does not
//! register `phone` / `ctx` and this surface cannot advertise them. The JNI
//! `capsJsonNative` call always asks for the no-bridge capability set, which is
//! exactly what `run` can execute.
//!
//! # The one stdin fact (`jaq_reads_stdin`)
//!
//! The C ABI has no stdin channel, so `jaq FILTER` without a file operand and
//! without `-n` has nothing to read. [`jaq_reads_stdin`] answers whether one
//! argv has that shape, by asking `pdsh-jaq`'s own parser: the jq option
//! grammar (option values, grouped short flags such as `-rn`, `--` termination)
//! stays a single Rust implementation, and the Kotlin exec adapter only has to
//! refuse the shape. The JNI entry is `NativeShell.jaqReadsStdinNative`.

use std::ffi::{c_void, CStr, CString};
use std::fmt;
use std::sync::Mutex;

use pdsh_ffi::{
    pdsh_caps_json_with_bridge, pdsh_join, pdsh_run, pdsh_version, XzCallbacks, XzEnvPair,
    XzLimits, XzMount, XzRequest,
};

/// Stable code of arguments that cannot describe a run.
pub const CODE_INPUT_INVALID: &str = "SHELL_INPUT_INVALID";
/// Stable code of a run the FFI refused to start or could not join.
pub const CODE_START_FAILED: &str = "SHELL_START_FAILED";
/// Stable code of a capability JSON or version that could not be read.
pub const CODE_CAPS_FAILED: &str = "SHELL_CAPS_FAILED";

/// The bytes of the Kotlin frame header: exit code and stdout length.
pub const FRAME_HEADER_BYTES: usize = 8;

/// A failure of one shell bridge operation.
///
/// `Display` renders `"<CODE>: <detail>"`, the one message format the Kotlin
/// binding translates into `AcceleratorException`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShellError {
    /// The JNI arguments cannot describe a run.
    Input(String),
    /// `pdsh_run` or `pdsh_join` refused the request.
    Start(String),
    /// The capability JSON or the version string could not be read.
    Caps(String),
}

impl ShellError {
    /// The stable code that prefixes the message.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Input(_) => CODE_INPUT_INVALID,
            Self::Start(_) => CODE_START_FAILED,
            Self::Caps(_) => CODE_CAPS_FAILED,
        }
    }
}

impl fmt::Display for ShellError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let detail = match self {
            Self::Input(detail) | Self::Start(detail) | Self::Caps(detail) => detail,
        };
        write!(formatter, "{}: {detail}", self.code())
    }
}

/// Resource limits of one run (the `XzLimits` struct of the C ABI).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ShellLimits {
    /// Wall-clock deadline in milliseconds; `0` means no deadline.
    pub timeout_ms: u64,
    /// Captured bytes per output stream.
    pub max_output_bytes: usize,
    /// Maximum number of files one command may open.
    pub max_files: usize,
    /// Maximum size in bytes of one file a command may read.
    pub max_file_bytes: u64,
}

/// One accelerator invocation, already resolved to guest paths.
///
/// `argv[0]` names the accelerator (`rg`, `jaq`, ...); the FFI's registry
/// dispatches on it. Mounts are guest-to-host pairs whose guest side must be
/// under `/dsh` (`pdsh_core::MountTable`).
pub struct ShellRequest<'a> {
    /// The full argument vector, `argv[0]` included.
    pub argv: &'a [String],
    /// Absolute guest working directory.
    pub cwd: &'a str,
    /// Environment variables with non-`NULL` values.
    pub env: &'a [(String, String)],
    /// Guest-to-host mounts; at least one.
    pub mounts: &'a [(String, String)],
    /// Resource limits of this invocation.
    pub limits: ShellLimits,
}

/// The completed result of one run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellResult {
    /// The command's exit code (0, 1, 2, ..., 124, 130, 127, 70).
    pub exit_code: i32,
    /// The retained stdout, already truncated to the output budget.
    pub stdout: Vec<u8>,
    /// The retained stderr, already truncated to the output budget.
    pub stderr: Vec<u8>,
}

/// The version string of the linked `pdsh-ffi`.
///
/// # Errors
/// [`ShellError::Caps`] if the C ABI ever returns a NULL pointer (it is
/// documented never to; this is a defect, not a normal state).
pub fn version() -> Result<String, ShellError> {
    // SAFETY: `pdsh_version` returns a pointer to a static NUL-terminated
    // string that must not be freed (xzshell.h).
    let pointer = pdsh_version();
    if pointer.is_null() {
        return Err(ShellError::Caps("pdsh_version returned NULL".to_string()));
    }
    // SAFETY: non-NULL and NUL-terminated, per the C ABI above.
    Ok(unsafe { CStr::from_ptr(pointer) }
        .to_string_lossy()
        .into_owned())
}

/// The capability JSON of the linked registry.
///
/// `has_tool_bridge` is the FFI's switch for `phone` / `ctx`; this bridge has no
/// host tool callback, so the JNI entry point always passes `false`. The buffer
/// protocol of the C ABI (query length with a NULL buffer, then copy) is wrapped
/// here so no other module hand-rolls it.
///
/// # Errors
/// [`ShellError::Caps`] when the ABI reports a non-positive length, copies a
/// different number of bytes than it reported, or returns non-UTF-8 JSON.
pub fn caps_json(has_tool_bridge: bool) -> Result<String, ShellError> {
    let flag = i32::from(has_tool_bridge);
    // SAFETY: a NULL buffer only asks the C ABI for the JSON length; the
    // pointer is not dereferenced by the ABI in that case.
    let needed = unsafe { pdsh_caps_json_with_bridge(flag, std::ptr::null_mut(), 0) };
    if needed <= 0 {
        return Err(ShellError::Caps(format!(
            "pdsh_caps_json_with_bridge reported length {needed}"
        )));
    }
    let mut buffer = vec![0u8; needed as usize];
    // SAFETY: `buffer` is writable for exactly `needed` bytes. The ABI writes at
    // most `cap` bytes, writes nothing when `cap` is too small, and returns the
    // data length; `cap == needed` therefore copies the whole JSON without a
    // NUL terminator, which is what is checked below.
    let written = unsafe { pdsh_caps_json_with_bridge(flag, buffer.as_mut_ptr(), buffer.len()) };
    if written != needed {
        return Err(ShellError::Caps(format!(
            "pdsh_caps_json_with_bridge reported {needed} bytes but wrote {written}"
        )));
    }
    String::from_utf8(buffer)
        .map_err(|error| ShellError::Caps(format!("the capability JSON is not UTF-8: {error}")))
}

/// Runs one accelerator through `pdsh-ffi` and waits for it to finish.
///
/// The deadline is armed by the FFI when the run starts (`request_start_nanos`
/// is zero, the C ABI's "start now" sentinel); the marshalling time before the
/// call is not charged to the budget.
///
/// # Errors
/// * [`ShellError::Input`] when the request cannot be expressed in the C ABI
///   (empty `argv`, a NUL in any string, a relative `cwd`, no mounts, an
///   environment name containing `=`).
/// * [`ShellError::Start`] when `pdsh_run` returns `-1` (it copies the request
///   and spawns the worker; `-1` means the request was refused or the worker
///   could not start) or `pdsh_join` does not know the handle it just returned.
pub fn run(request: &ShellRequest<'_>) -> Result<ShellResult, ShellError> {
    validate(request)?;

    let argv: Vec<CString> = request
        .argv
        .iter()
        .map(|argument| owned(argument, "an argv element"))
        .collect::<Result<_, _>>()?;
    let cwd = owned(request.cwd, "cwd")?;
    let env_names: Vec<CString> = request
        .env
        .iter()
        .map(|(name, _)| owned(name, "an environment name"))
        .collect::<Result<_, _>>()?;
    let env_values: Vec<CString> = request
        .env
        .iter()
        .map(|(_, value)| owned(value, "an environment value"))
        .collect::<Result<_, _>>()?;
    let mount_guests: Vec<CString> = request
        .mounts
        .iter()
        .map(|(guest, _)| owned(guest, "a mount guest path"))
        .collect::<Result<_, _>>()?;
    let mount_hosts: Vec<CString> = request
        .mounts
        .iter()
        .map(|(_, host)| owned(host, "a mount host path"))
        .collect::<Result<_, _>>()?;

    let argv_pointers: Vec<*const std::ffi::c_char> =
        argv.iter().map(|argument| argument.as_ptr()).collect();
    let env_pairs: Vec<XzEnvPair> = env_names
        .iter()
        .zip(&env_values)
        .map(|(name, value)| XzEnvPair {
            key: name.as_ptr(),
            value: value.as_ptr(),
        })
        .collect();
    let mounts: Vec<XzMount> = mount_guests
        .iter()
        .zip(&mount_hosts)
        .map(|(guest, host)| XzMount {
            guest: guest.as_ptr(),
            host: host.as_ptr(),
        })
        .collect();

    let xz_request = XzRequest {
        argc: argv_pointers.len(),
        argv: argv_pointers.as_ptr(),
        cwd: cwd.as_ptr(),
        env_count: env_pairs.len(),
        env: if env_pairs.is_empty() {
            std::ptr::null()
        } else {
            env_pairs.as_ptr()
        },
        mount_count: mounts.len(),
        mounts: mounts.as_ptr(),
        limits: XzLimits {
            timeout_ms: request.limits.timeout_ms,
            max_output_bytes: request.limits.max_output_bytes,
            max_files: request.limits.max_files,
            max_file_bytes: request.limits.max_file_bytes,
        },
        // Zero is the ABI's "not supplied": the deadline is armed when the run
        // starts, so the Kotlin side passes a relative timeout.
        request_start_nanos: 0,
    };
    let callbacks = XzCallbacks {
        on_stdout: Some(capture_stdout),
        on_stderr: Some(capture_stderr),
        on_exit: None,
        // No host bridge: the FFI registers neither `phone` nor `ctx`, matching
        // the no-bridge capability JSON this module asks for.
        call_tool: None,
    };
    let capture = Capture::default();
    let user = (&capture as *const Capture).cast_mut().cast::<c_void>();

    // SAFETY: every pointer in `xz_request` refers to a local that outlives the
    // call (`pdsh_run` copies the request but borrows its C strings), and
    // `user` refers to `capture`, which lives until after `pdsh_join` returns.
    // The FFI invokes the callbacks only from its worker thread, before join.
    let handle = unsafe { pdsh_run(&xz_request, &callbacks, user) };
    if handle <= 0 {
        return Err(ShellError::Start(format!(
            "pdsh_run refused the request (handle {handle})"
        )));
    }
    // SAFETY: `handle` is the positive handle `pdsh_run` just returned, and it
    // is joined exactly once here; the FFI invalidates it afterwards.
    let exit_code = pdsh_join(handle);
    if exit_code < 0 {
        return Err(ShellError::Start(format!(
            "pdsh_join no longer knows handle {handle}"
        )));
    }

    Ok(ShellResult {
        exit_code,
        stdout: capture.take_stdout(),
        stderr: capture.take_stderr(),
    })
}

/// Whether one `jaq` argv would read the process's standard input.
///
/// The C ABI has no stdin channel, so `jaq FILTER` without a file operand and
/// without `-n` has nothing to read on Android. The Kotlin exec adapter refuses
/// exactly that shape instead of letting the command read whatever standard
/// input the host process happens to have (on a device that is `/dev/null`; in
/// a JVM host it can be a pipe that never closes, so the refusal is also a way
/// to avoid a blocking read).
///
/// The decision comes from `pdsh-jaq`'s own parser ([`pdsh_jaq::args::parse`]),
/// not from a second argv reader here: the option grammar (`--arg` /
/// `--argjson` / `--indent` values, grouped short flags such as `-rn`, `--`
/// termination) has exactly one implementation, the Rust one the command itself
/// uses. An argv the parser rejects is not a stdin read: the command exits 2 as
/// a usage error before opening anything.
pub fn jaq_reads_stdin(argv: &[String]) -> bool {
    match pdsh_jaq::args::parse(argv) {
        Ok(cli) => cli.files.is_empty() && !cli.null_input && !cli.help && !cli.version,
        Err(_) => false,
    }
}

/// Frames one result for the Kotlin binding (layout in the module docs).
///
/// # Errors
/// [`ShellError::Start`] when a stream is longer than a `u32` length field can
/// describe, which cannot happen under the output budget this bridge passes.
pub fn encode_frame(result: &ShellResult) -> Result<Vec<u8>, ShellError> {
    let stdout_length = u32::try_from(result.stdout.len()).map_err(|_| {
        ShellError::Start("the stdout stream does not fit the 32-bit frame length".to_string())
    })?;
    let mut frame =
        Vec::with_capacity(FRAME_HEADER_BYTES + result.stdout.len() + result.stderr.len());
    frame.extend_from_slice(&result.exit_code.to_be_bytes());
    frame.extend_from_slice(&stdout_length.to_be_bytes());
    frame.extend_from_slice(&result.stdout);
    frame.extend_from_slice(&result.stderr);
    Ok(frame)
}

/// Rejects a request before any C string is built.
fn validate(request: &ShellRequest<'_>) -> Result<(), ShellError> {
    if request.argv.is_empty() {
        return Err(ShellError::Input(
            "argv must name the accelerator".to_string(),
        ));
    }
    if request.argv[0].is_empty() {
        return Err(ShellError::Input("argv[0] must not be empty".to_string()));
    }
    if !request.cwd.starts_with('/') {
        return Err(ShellError::Input(
            "cwd must be an absolute guest path".to_string(),
        ));
    }
    if request.mounts.is_empty() {
        return Err(ShellError::Input(
            "at least one mount is required".to_string(),
        ));
    }
    for (guest, host) in request.mounts {
        if !guest.starts_with('/') {
            return Err(ShellError::Input(
                "a mount guest path must be absolute".to_string(),
            ));
        }
        if host.is_empty() {
            return Err(ShellError::Input(
                "a mount host path must not be empty".to_string(),
            ));
        }
    }
    for (name, _) in request.env {
        if name.is_empty() || name.contains('=') {
            return Err(ShellError::Input(format!(
                "environment name {name:?} must be non-empty and must not contain '='"
            )));
        }
    }
    Ok(())
}

/// Builds one NUL-terminated C string, naming the field in the failure.
fn owned(value: &str, field: &str) -> Result<CString, ShellError> {
    CString::new(value).map_err(|_| ShellError::Input(format!("{field} contains a NUL byte")))
}

/// The two retained output streams of one run.
#[derive(Default)]
struct Capture {
    stdout: Mutex<Vec<u8>>,
    stderr: Mutex<Vec<u8>>,
}

impl Capture {
    fn take_stdout(&self) -> Vec<u8> {
        take(&self.stdout)
    }

    fn take_stderr(&self) -> Vec<u8> {
        take(&self.stderr)
    }
}

fn take(stream: &Mutex<Vec<u8>>) -> Vec<u8> {
    std::mem::take(&mut *stream.lock().unwrap_or_else(|poison| poison.into_inner()))
}

/// Retains one stdout chunk the FFI delivers before `pdsh_join` returns.
///
/// # Safety
/// `user` must be the `*const Capture` passed to `pdsh_run`, and `data` must be
/// valid for `length` bytes for the duration of the call.
unsafe extern "C" fn capture_stdout(user: *mut c_void, data: *const u8, length: usize) {
    // SAFETY: forwarded from `pdsh_run`'s contract; checked for the two null
    // cases the C side may legitimately produce.
    let Some(capture) = (unsafe { capture(user) }) else {
        return;
    };
    if data.is_null() || length == 0 {
        return;
    }
    // SAFETY: `pdsh_run` guarantees a readable buffer of `length` bytes.
    let chunk = unsafe { std::slice::from_raw_parts(data, length) };
    capture
        .stdout
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .extend_from_slice(chunk);
}

/// Retains one stderr chunk; the safety contract is [`capture_stdout`]'s.
///
/// # Safety
/// Same as [`capture_stdout`].
unsafe extern "C" fn capture_stderr(user: *mut c_void, data: *const u8, length: usize) {
    // SAFETY: forwarded from `pdsh_run`'s contract; checked for the two null
    // cases the C side may legitimately produce.
    let Some(capture) = (unsafe { capture(user) }) else {
        return;
    };
    if data.is_null() || length == 0 {
        return;
    }
    // SAFETY: `pdsh_run` guarantees a readable buffer of `length` bytes.
    let chunk = unsafe { std::slice::from_raw_parts(data, length) };
    capture
        .stderr
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .extend_from_slice(chunk);
}

/// # Safety
/// `user` must be the `*const Capture` this module passed to `pdsh_run`.
unsafe fn capture<'a>(user: *mut c_void) -> Option<&'a Capture> {
    if user.is_null() {
        return None;
    }
    // SAFETY: the caller guarantees the pointer came from `pdsh_run`'s `user`
    // argument, which is a live `Capture` until `pdsh_join` returns.
    Some(unsafe { &*user.cast::<Capture>() })
}

#[cfg(test)]
mod tests {
    use super::{
        caps_json, encode_frame, jaq_reads_stdin, run, version, ShellError, ShellLimits,
        ShellRequest, FRAME_HEADER_BYTES,
    };
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    struct TestTree {
        root: PathBuf,
    }

    impl TestTree {
        fn new(tag: &str) -> Self {
            let unique = COUNTER.fetch_add(1, Ordering::SeqCst);
            let root = std::env::temp_dir().join(format!(
                "pdsh-jni-shell-{}-{}-{}",
                std::process::id(),
                unique,
                tag
            ));
            fs::create_dir_all(&root).unwrap();
            TestTree { root }
        }

        fn workspace(&self) -> &Path {
            &self.root
        }

        fn write(&self, name: &str, text: &str) {
            fs::write(self.root.join(name), text).unwrap();
        }
    }

    impl Drop for TestTree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn limits() -> ShellLimits {
        ShellLimits {
            timeout_ms: 10_000,
            max_output_bytes: 1_048_576,
            max_files: 100,
            max_file_bytes: 1_048_576,
        }
    }

    fn request<'a>(
        argv: &'a [String],
        cwd: &'a str,
        mounts: &'a [(String, String)],
    ) -> ShellRequest<'a> {
        ShellRequest {
            argv,
            cwd,
            env: &[],
            mounts,
            limits: limits(),
        }
    }

    fn workspace_mount(tree: &TestTree) -> (String, String) {
        (
            "/dsh/workspace".to_string(),
            tree.workspace().display().to_string(),
        )
    }

    #[test]
    fn version_matches_the_c_abi() {
        let reported = version().expect("version");
        // SAFETY: `pdsh_version` is the same never-NULL static string.
        let from_c = unsafe { std::ffi::CStr::from_ptr(pdsh_ffi::pdsh_version()) }
            .to_str()
            .expect("UTF-8");
        assert_eq!(reported, from_c);
        assert!(!reported.is_empty());
    }

    #[test]
    fn caps_json_reports_exactly_what_this_bridge_can_run() {
        let without_bridge = caps_json(false).expect("caps");
        for name in ["jaq", "jq", "rg", "ts-parse", "ts-query"] {
            assert!(
                without_bridge.contains(&format!("\"{name}\"")),
                "missing {name} in {without_bridge}"
            );
        }
        assert!(!without_bridge.contains("\"phone\""));
        assert!(!without_bridge.contains("\"ctx\""));

        // The host-bridge set exists in the linked registry, but this bridge
        // never supplies `call_tool`, so it must never be the set it asks for.
        let with_bridge = caps_json(true).expect("caps");
        assert!(with_bridge.contains("\"phone\""));
        assert!(with_bridge.contains("\"ctx\""));
    }

    #[test]
    fn an_invalid_request_is_rejected_before_the_ffi() {
        let argv: Vec<String> = Vec::new();
        let mounts = vec![("/dsh/workspace".to_string(), "/tmp".to_string())];
        let empty = request(&argv, "/dsh/workspace", &mounts);
        assert!(matches!(run(&empty), Err(ShellError::Input(_))));

        let argv = vec!["rg".to_string()];
        let relative = request(&argv, "workspace", &mounts);
        assert!(matches!(run(&relative), Err(ShellError::Input(_))));

        let no_mounts: Vec<(String, String)> = Vec::new();
        let unmounted = request(&argv, "/dsh/workspace", &no_mounts);
        assert!(matches!(run(&unmounted), Err(ShellError::Input(_))));

        let nul = vec!["rg".to_string(), "a\0b".to_string()];
        let with_nul = request(&nul, "/dsh/workspace", &mounts);
        assert!(matches!(run(&with_nul), Err(ShellError::Input(_))));
    }

    #[test]
    fn a_missing_mount_host_is_a_start_failure() {
        let argv = vec!["rg".to_string(), "--version".to_string()];
        let missing = vec![(
            "/dsh/workspace".to_string(),
            "/definitely/not/here/pdsh-jni".to_string(),
        )];
        let request = request(&argv, "/dsh/workspace", &missing);
        let error = run(&request).expect_err("the FFI must refuse a missing mount");
        assert_eq!(error.code(), super::CODE_START_FAILED);
    }

    #[test]
    fn rg_runs_through_the_ffi_and_frames_both_streams() {
        let tree = TestTree::new("rg");
        tree.write("a.txt", "hello\nworld\n");
        let mounts = vec![workspace_mount(&tree)];
        let argv = vec!["rg".to_string(), "-n".to_string(), "hello".to_string()];
        let request = request(&argv, "/dsh/workspace", &mounts);
        let result = run(&request).expect("rg must run");
        assert_eq!(result.exit_code, 0);
        let stdout = String::from_utf8(result.stdout.clone()).unwrap();
        assert!(stdout.contains("a.txt:1:hello"), "{stdout}");
        assert!(result.stderr.is_empty());

        let frame = encode_frame(&result).unwrap();
        assert!(frame.len() >= FRAME_HEADER_BYTES + result.stdout.len());
        assert_eq!(
            i32::from_be_bytes(frame[0..4].try_into().unwrap()),
            result.exit_code
        );
        let stdout_length = u32::from_be_bytes(frame[4..8].try_into().unwrap()) as usize;
        assert_eq!(stdout_length, result.stdout.len());
        assert_eq!(&frame[8..8 + stdout_length], result.stdout.as_slice());
    }

    #[test]
    fn jaq_reads_stdin_follows_the_rust_parser() {
        let argv = |items: &[&str]| -> Vec<String> {
            items.iter().map(|item| (*item).to_string()).collect()
        };
        // `jaq FILTER` with no file operand and no `-n` reads stdin.
        assert!(jaq_reads_stdin(&argv(&["jaq", "."])));
        assert!(jaq_reads_stdin(&argv(&[
            "jaq", "--arg", "name", "value", "."
        ])));
        // Grouped short flags still count as `-n`; a naive `contains("-n")`
        // would miss this and refuse a valid null-input invocation.
        assert!(!jaq_reads_stdin(&argv(&["jaq", "-rn", "."])));
        assert!(!jaq_reads_stdin(&argv(&["jaq", "-n", "."])));
        assert!(!jaq_reads_stdin(&argv(&["jaq", ".", "in.json"])));
        assert!(!jaq_reads_stdin(&argv(&["jaq", "--help"])));
        assert!(!jaq_reads_stdin(&argv(&["jaq", "--version"])));
        // A usage error is not a stdin read: the command exits 2 first.
        assert!(!jaq_reads_stdin(&argv(&["jaq"])));
        assert!(!jaq_reads_stdin(&argv(&["jaq", "--nonsense", "."])));
    }

    #[test]
    fn rg_reports_no_match_as_exit_one_without_output() {
        let tree = TestTree::new("nomatch");
        tree.write("a.txt", "hello\n");
        let mounts = vec![workspace_mount(&tree)];
        let argv = vec!["rg".to_string(), "absent".to_string()];
        let request = request(&argv, "/dsh/workspace", &mounts);
        let result = run(&request).expect("rg must run");
        assert_eq!(result.exit_code, 1);
        assert!(result.stdout.is_empty());
    }

    #[test]
    fn output_is_truncated_at_the_budget_before_the_frame() {
        let tree = TestTree::new("budget");
        tree.write("a.txt", &"x".repeat(4096));
        let mounts = vec![workspace_mount(&tree)];
        let argv = vec!["rg".to_string(), "x".to_string()];
        let mut request = request(&argv, "/dsh/workspace", &mounts);
        request.limits.max_output_bytes = 64;
        let result = run(&request).expect("rg must run");
        assert_eq!(result.exit_code, 0);
        let stdout = String::from_utf8(result.stdout).unwrap();
        assert!(stdout.contains("pdsh-shell truncated"), "{stdout}");
        assert!(stdout.len() < 256, "{} bytes", stdout.len());
    }

    #[test]
    fn a_usage_error_is_an_exit_code_and_stderr_not_a_native_error() {
        let tree = TestTree::new("usage");
        let mounts = vec![workspace_mount(&tree)];
        let argv = vec!["rg".to_string(), "--not-a-real-flag".to_string()];
        let request = request(&argv, "/dsh/workspace", &mounts);
        let result = run(&request).expect("a usage error is not an FFI failure");
        assert_eq!(result.exit_code, 2);
        assert!(!result.stderr.is_empty());
    }
}
