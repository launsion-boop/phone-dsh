// SPDX-License-Identifier: MIT
//! C ABI of the phone-dsh phone DSH pdsh-shell read-only accelerators.
//!
//! `pdsh-ffi` wraps [`pdsh_core`] for the Swift host. It does not expose a general
//! shell: the registry contains the read-only accelerators only, and a command
//! is never able to write the workspace because the VFS has no write operation.
//!
//! The exported functions and the C layout of the request/callback structs are
//! declared in `include/xzshell.h`; `header_matches_exports` keeps the two
//! sides in sync.

use std::any::Any;
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{self, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use pdsh_core::command::{EXIT_CANCELLED, EXIT_INTERNAL};
#[cfg(test)]
use pdsh_core::command::Command;
use pdsh_core::commands::{CapsCommand, EchoCommand};
use pdsh_core::{
    CancelToken, Ctx, Error, HostBridge, Limits, MountSpec, MountTable, Registry, StdFsVfs,
};

/// Exit code of a caught Rust panic.
pub const EXIT_PANIC: i32 = 70;
/// Exit code of a run that hit its deadline.
pub const EXIT_TIMED_OUT: i32 = 124;
/// Exit code of an unknown command.
pub const EXIT_UNKNOWN_COMMAND: i32 = 127;

/// Initial buffer size of the host tool bridge, in bytes.
const INITIAL_TOOL_BUFFER: usize = 4096;
/// Upper bound for one host tool result, in bytes.
const MAX_TOOL_RESULT_BYTES: usize = 16 * 1024 * 1024;

/// Limits of one invocation. A zero `timeout_ms` means "no deadline".
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct XzLimits {
    /// Wall-clock deadline in milliseconds; `0` means no deadline.
    pub timeout_ms: u64,
    /// Captured bytes per output stream.
    pub max_output_bytes: usize,
    /// Maximum number of files one command may open.
    pub max_files: usize,
    /// Maximum size in bytes of one file a command may read.
    pub max_file_bytes: u64,
}

/// One environment pair. Both pointers are NUL-terminated UTF-8 strings.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct XzEnvPair {
    /// Variable name.
    pub key: *const c_char,
    /// Variable value.
    pub value: *const c_char,
}

/// One guest-to-host mount. Guest paths are absolute under `/dsh`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct XzMount {
    /// Absolute guest path, for example `/dsh/workspace`.
    pub guest: *const c_char,
    /// Existing host directory.
    pub host: *const c_char,
}

/// One execution request. `argv` includes `argv[0]`, the command name.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct XzRequest {
    /// Number of arguments.
    pub argc: usize,
    /// Argument vector (`argc` NUL-terminated UTF-8 strings).
    pub argv: *const *const c_char,
    /// Absolute guest working directory.
    pub cwd: *const c_char,
    /// Number of environment pairs.
    pub env_count: usize,
    /// Environment pairs, or NULL when `env_count` is zero.
    pub env: *const XzEnvPair,
    /// Number of mounts.
    pub mount_count: usize,
    /// Mount pairs.
    pub mounts: *const XzMount,
    /// Resource limits.
    pub limits: XzLimits,
    /// Monotonic start of the request, from [`pdsh_monotonic_nanos`]. Zero
    /// means "not supplied": the deadline is then armed when `pdsh_run`
    /// starts, preserving the old ABI behaviour. A non-zero value makes the
    /// request parse and C-string construction spend the original budget.
    pub request_start_nanos: u64,
}

/// Output callback; the bytes are valid only during the call.
pub type XzOutputCallback = Option<unsafe extern "C" fn(user: *mut c_void, ptr: *const u8, len: usize)>;
/// Terminal callback.
pub type XzExitCallback = Option<unsafe extern "C" fn(user: *mut c_void, code: i32)>;
/// Host tool bridge callback.
pub type XzCallToolCallback = Option<
    unsafe extern "C" fn(
        user: *mut c_void,
        name: *const c_char,
        args_json: *const c_char,
        out_buf: *mut u8,
        out_cap: usize,
    ) -> isize,
>;

/// Callbacks of one run. Any member may be NULL.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct XzCallbacks {
    /// Retained stdout, delivered once before `on_exit`.
    pub on_stdout: XzOutputCallback,
    /// Retained stderr, delivered once before `on_exit`.
    pub on_stderr: XzOutputCallback,
    /// Terminal callback, delivered from the worker thread.
    pub on_exit: XzExitCallback,
    /// `phone` / `ctx` tool forwarding.
    pub call_tool: XzCallToolCallback,
}

static MONOTONIC_EPOCH: OnceLock<Instant> = OnceLock::new();

fn monotonic_epoch() -> Instant {
    *MONOTONIC_EPOCH.get_or_init(Instant::now)
}

/// Monotonic nanoseconds since this process first called the function.
///
/// The host samples this at the start of an exec request and stores it in
/// [`XzRequest::request_start_nanos`], so the FFI can arm the cancel-token
/// deadline before parsing the request without restarting the budget.
#[no_mangle]
pub extern "C" fn pdsh_monotonic_nanos() -> u64 {
    // Initialise the epoch before sampling. Zero is the C ABI's legacy
    // "start now" sentinel, so even the first clock sample must be non-zero.
    let epoch = monotonic_epoch();
    let elapsed = epoch.elapsed();
    u64::try_from(elapsed.as_nanos()).unwrap_or(u64::MAX).max(1)
}

/// The absolute deadline for one request. With a host-supplied start the
/// deadline is anchored at that start; a zero start falls back to arming from
/// now, which is the opt-out behaviour for callers that initialise the field to zero.
/// The current request layout must still be used when compiling C callers.
fn request_deadline(request_start_nanos: u64, timeout_ms: u64) -> Instant {
    let timeout = Duration::from_millis(timeout_ms);
    if request_start_nanos == 0 {
        Instant::now() + timeout
    } else {
        monotonic_epoch() + Duration::from_nanos(request_start_nanos) + timeout
    }
}

/// Version string of the linked pdsh-shell. Never NULL; do not free.
#[no_mangle]
pub extern "C" fn pdsh_version() -> *const c_char {
    const VERSION: &[u8] = concat!(env!("CARGO_PKG_VERSION"), "\0").as_bytes();
    VERSION.as_ptr() as *const c_char
}

/// Capability JSON of the linked registry.
///
/// Returns the JSON length in bytes. A NULL `buf` only reports the length; a
/// too-small `cap` writes nothing and returns the negated length; otherwise the
/// JSON is copied and NUL-terminated when `cap` is larger than the length.
#[no_mangle]
pub unsafe extern "C" fn pdsh_caps_json(buf: *mut u8, cap: usize) -> isize {
    pdsh_caps_json_with_bridge(1, buf, cap)
}

/// Capability JSON for a caller with or without a host tool bridge.
///
/// `has_tool_bridge` is a C `int32_t` (zero means "no bridge"). When it is
/// zero the `phone` / `ctx` accelerators are neither registered nor
/// advertised, matching what the caller can actually execute. The buffer
/// protocol is identical to [`pdsh_caps_json`].
#[no_mangle]
pub unsafe extern "C" fn pdsh_caps_json_with_bridge(
    has_tool_bridge: i32,
    buf: *mut u8,
    cap: usize,
) -> isize {
    let json = caps_json(has_tool_bridge != 0).into_bytes();
    let length = json.len();
    if buf.is_null() {
        return length as isize;
    }
    if cap < length {
        return -(length as isize);
    }
    std::ptr::copy_nonoverlapping(json.as_ptr(), buf, length);
    if cap > length {
        *buf.add(length) = 0;
    }
    length as isize
}

/// Start one command and return a positive handle, or `-1` for an invalid
/// request. The command runs on a worker thread; call [`pdsh_join`] to wait.
#[no_mangle]
pub unsafe extern "C" fn pdsh_run(
    req: *const XzRequest,
    cb: *const XzCallbacks,
    user: *mut c_void,
) -> i32 {
    match panic::catch_unwind(AssertUnwindSafe(|| pdsh_run_inner(req, cb, user))) {
        Ok(handle) => handle,
        Err(_) => -1,
    }
}

/// Request cancellation of a live handle. Returns `0` or `-1` if unknown.
#[no_mangle]
pub extern "C" fn pdsh_cancel(handle: i32) -> i32 {
    let table = job_table().lock().unwrap_or_else(|poison| poison.into_inner());
    match table.get(&handle) {
        Some(job) => {
            job.cancel.cancel();
            0
        }
        None => -1,
    }
}

/// Wait for a handle, return its exit code and invalidate the handle.
#[no_mangle]
pub extern "C" fn pdsh_join(handle: i32) -> i32 {
    let job = {
        let mut table = job_table().lock().unwrap_or_else(|poison| poison.into_inner());
        table.remove(&handle)
    };
    match job {
        Some(job) => job.thread.join().unwrap_or(EXIT_PANIC),
        None => -1,
    }
}

// ---------------------------------------------------------------- internals

struct Job {
    cancel: CancelToken,
    thread: JoinHandle<i32>,
}

static JOBS: OnceLock<Mutex<HashMap<i32, Job>>> = OnceLock::new();
static NEXT_HANDLE: AtomicI32 = AtomicI32::new(1);

fn job_table() -> &'static Mutex<HashMap<i32, Job>> {
    JOBS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn next_handle() -> i32 {
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    if handle <= 0 {
        NEXT_HANDLE.store(1, Ordering::Relaxed);
        1
    } else {
        handle
    }
}

/// Raw user pointer passed to the worker thread.
#[derive(Clone, Copy)]
struct UserPtr(*mut c_void);

// The host owns the pointer and keeps the object alive until pdsh_join returns
// (documented in xzshell.h); the worker only forwards it to the callbacks.
unsafe impl Send for UserPtr {}
unsafe impl Sync for UserPtr {}

struct OwnedRequest {
    argv: Vec<String>,
    cwd: PathBuf,
    env: Vec<(String, String)>,
    mounts: MountTable,
    limits: Limits,
}

fn caps_json(has_tool_bridge: bool) -> String {
    production_registry(has_tool_bridge).caps_json(&Limits::default())
}

/// The production registry merged with the unadvertised diagnostics.
///
/// `pdsh-all` owns the read-only accelerators and only registers `phone` /
/// `ctx` when a host bridge exists. `echo` and `pdsh-caps` stay available for
/// the FFI tests but are never advertised.
fn production_registry(has_tool_bridge: bool) -> Registry {
    let mut registry = pdsh_all::pdsh_shell_accelerators_with_bridge(has_tool_bridge);
    registry.register(Box::new(EchoCommand::new()));
    registry.register(Box::new(CapsCommand::new()));
    registry
}

fn default_registry(has_tool_bridge: bool) -> Registry {
    let registry = production_registry(has_tool_bridge);
    #[cfg(test)]
    {
        let mut registry = registry;
        registry.register(Box::new(PanicCommand));
        registry
    }
    #[cfg(not(test))]
    {
        registry
    }
}

#[cfg(test)]
struct PanicCommand;

#[cfg(test)]
impl Command for PanicCommand {
    fn name(&self) -> &str {
        "pdsh-panic"
    }

    fn run(&self, _argv: &[String], _ctx: &mut Ctx<'_>) -> i32 {
        panic!("intentional test panic");
    }
}

unsafe fn pdsh_run_inner(
    req: *const XzRequest,
    cb: *const XzCallbacks,
    user: *mut c_void,
) -> i32 {
    // Arm the cancel token before parsing anything. The request strings are
    // only borrowed here; `parse_request` copies them below. A host-supplied
    // start anchors the deadline at the real request start, so a slow parse
    // spends the original budget instead of granting a fresh timeout.
    let (timeout_ms, request_start_nanos) = if req.is_null() {
        (0, 0)
    } else {
        let request = &*req;
        (request.limits.timeout_ms, request.request_start_nanos)
    };
    let cancel = CancelToken::new();
    if timeout_ms > 0 {
        cancel.set_deadline(request_deadline(request_start_nanos, timeout_ms));
    }
    let request = match parse_request(req) {
        Ok(request) => request,
        Err(()) => return -1,
    };
    let callbacks = match parse_callbacks(cb) {
        Ok(callbacks) => callbacks,
        Err(()) => return -1,
    };
    let thread_cancel = cancel.clone();
    let user = UserPtr(user);
    let worker = match thread::Builder::new()
        .name("pdsh-shell-run".to_string())
        .spawn(move || run_job(request, callbacks, user, thread_cancel))
    {
        Ok(worker) => worker,
        Err(_) => return -1,
    };
    let mut table = job_table().lock().unwrap_or_else(|poison| poison.into_inner());
    loop {
        let handle = next_handle();
        if let std::collections::hash_map::Entry::Vacant(entry) = table.entry(handle) {
            entry.insert(Job {
                cancel,
                thread: worker,
            });
            return handle;
        }
    }
}

unsafe fn parse_callbacks(cb: *const XzCallbacks) -> Result<XzCallbacks, ()> {
    if cb.is_null() {
        return Err(());
    }
    Ok(*cb)
}

unsafe fn parse_request(req: *const XzRequest) -> Result<OwnedRequest, ()> {
    if req.is_null() {
        return Err(());
    }
    let req = &*req;
    if req.argc == 0 || req.argv.is_null() {
        return Err(());
    }
    let mut argv = Vec::with_capacity(req.argc.min(4096));
    for index in 0..req.argc {
        let pointer = *req.argv.add(index);
        argv.push(c_string(pointer)?);
    }
    if argv[0].is_empty() {
        return Err(());
    }
    let cwd = PathBuf::from(c_string(req.cwd)?);
    if !cwd.is_absolute() {
        return Err(());
    }

    let mut env = Vec::new();
    if req.env_count > 0 {
        if req.env.is_null() {
            return Err(());
        }
        let capacity = req.env_count.min(4096);
        env.reserve(capacity);
        for index in 0..req.env_count {
            let pair = &*req.env.add(index);
            let key = c_string(pair.key)?;
            let value = c_string(pair.value)?;
            if key.is_empty() || key.contains('=') || key.contains('\0') {
                return Err(());
            }
            env.push((key, value));
        }
    }

    if req.mount_count == 0 || req.mounts.is_null() {
        return Err(());
    }
    let mut specs = Vec::with_capacity(req.mount_count.min(64));
    for index in 0..req.mount_count {
        let mount = &*req.mounts.add(index);
        let guest = c_string(mount.guest)?;
        let host = c_string(mount.host)?;
        specs.push(MountSpec::new(guest, host));
    }
    let mounts = MountTable::new(specs).map_err(|_| ())?;
    if mounts.resolve(&cwd).is_err() {
        return Err(());
    }

    let limits = Limits::new(
        Duration::from_millis(req.limits.timeout_ms),
        req.limits.max_output_bytes,
        req.limits.max_files,
        req.limits.max_file_bytes,
    );
    Ok(OwnedRequest {
        argv,
        cwd,
        env,
        mounts,
        limits,
    })
}

unsafe fn c_string(pointer: *const c_char) -> Result<String, ()> {
    if pointer.is_null() {
        return Err(());
    }
    CStr::from_ptr(pointer)
        .to_str()
        .map(str::to_string)
        .map_err(|_| ())
}

fn run_job(
    request: OwnedRequest,
    callbacks: XzCallbacks,
    user: UserPtr,
    cancel: CancelToken,
) -> i32 {
    let finished = Arc::new((Mutex::new(false), Condvar::new()));
    let watchdog = start_watchdog(&cancel, finished.clone());
    let outcome = panic::catch_unwind(AssertUnwindSafe(|| {
        execute(&request, &callbacks, user, &cancel)
    }));
    let code = match outcome {
        Ok(code) => code,
        Err(payload) => {
            let message = format!("pdsh-shell: panic: {}\n", panic_message(payload.as_ref()));
            emit_output(callbacks.on_stderr, user, message.as_bytes());
            EXIT_PANIC
        }
    };
    {
        let (lock, condition) = &*finished;
        *lock.lock().unwrap_or_else(|poison| poison.into_inner()) = true;
        condition.notify_all();
    }
    if let Some(watchdog) = watchdog {
        let _ = watchdog.join();
    }
    if let Some(on_exit) = callbacks.on_exit {
        unsafe { on_exit(user.0, code) };
    }
    code
}

fn start_watchdog(
    cancel: &CancelToken,
    finished: Arc<(Mutex<bool>, Condvar)>,
) -> Option<JoinHandle<()>> {
    let deadline = cancel.deadline()?;
    let cancel = cancel.clone();
    thread::Builder::new()
        .name("pdsh-shell-watchdog".to_string())
        .spawn(move || {
            let (lock, condition) = &*finished;
            let mut done = lock.lock().unwrap_or_else(|poison| poison.into_inner());
            while !*done {
                let now = Instant::now();
                if now >= deadline {
                    break;
                }
                let wait = deadline - now;
                let (guard, _) = condition
                    .wait_timeout(done, wait)
                    .unwrap_or_else(|poison| poison.into_inner());
                done = guard;
            }
            let expired = !*done;
            drop(done);
            if expired {
                cancel.cancel();
            }
        })
        .ok()
}

fn execute(
    request: &OwnedRequest,
    callbacks: &XzCallbacks,
    user: UserPtr,
    cancel: &CancelToken,
) -> i32 {
    let vfs = StdFsVfs::new(request.mounts.clone());
    let bridge = CallbackBridge {
        callbacks: *callbacks,
        user,
        cancel: cancel.clone(),
        terminal_error: Mutex::new(None),
    };
    let mut ctx = Ctx::new(&vfs, &bridge, request.cwd.clone(), request.limits.clone())
        .with_cancel(cancel.clone());
    ctx.apply_env(request.env.iter().cloned());
    let registry = default_registry(callbacks.call_tool.is_some());

    let outcome = panic::catch_unwind(AssertUnwindSafe(|| {
        registry.run(&request.argv[0], &request.argv, &mut ctx)
    }));
    let mut code = match outcome {
        Ok(Ok(code)) => code,
        Ok(Err(Error::Cancelled)) => EXIT_CANCELLED,
        Ok(Err(Error::UnknownCommand(name))) => {
            let _ = ctx.emit_stderr_str(&format!("pdsh-shell: unknown command: {name}\n"));
            EXIT_UNKNOWN_COMMAND
        }
        Ok(Err(error)) => {
            let _ = ctx.emit_stderr_str(&format!("pdsh-shell: {error}\n"));
            EXIT_INTERNAL
        }
        Err(payload) => {
            let _ = ctx.emit_stderr_str(&format!(
                "pdsh-shell: panic: {}\n",
                panic_message(payload.as_ref())
            ));
            EXIT_PANIC
        }
    };
    // A command that ignores the token still must not report success after its
    // deadline; an explicit cancel wins over a normal exit.
    if code != EXIT_PANIC {
        if cancel.is_deadline_expired() {
            code = EXIT_TIMED_OUT;
        } else if cancel.is_cancelled() {
            code = EXIT_CANCELLED;
        }
    }
    let (stdout, mut stderr) = ctx.finish();
    // A token-triggered exit makes `Ctx::emit_stderr` refuse to write, so the
    // bridge's cancellation/deadline diagnostic would otherwise be lost. Add
    // it after the token check, outside the cancelled sink.
    if code == EXIT_TIMED_OUT || code == EXIT_CANCELLED {
        if let Some(message) = bridge.take_terminal_error() {
            if !stderr.data.ends_with(message.as_bytes()) {
                stderr.data.extend_from_slice(message.as_bytes());
            }
        }
    }
    emit_output(callbacks.on_stdout, user, &stdout.data);
    emit_output(callbacks.on_stderr, user, &stderr.data);
    code
}

fn emit_output(callback: XzOutputCallback, user: UserPtr, data: &[u8]) {
    if data.is_empty() {
        return;
    }
    if let Some(callback) = callback {
        unsafe { callback(user.0, data.as_ptr(), data.len()) };
    }
}

fn panic_message(payload: &(dyn Any + Send)) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_string()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "unknown panic".to_string()
    }
}

/// [`HostBridge`] that forwards one tool call through the C callback.
struct CallbackBridge {
    callbacks: XzCallbacks,
    user: UserPtr,
    cancel: CancelToken,
    /// Last terminal host failure. A cancelled stderr sink cannot emit it, so
    /// `execute` appends it after the token decides the 124/130 exit.
    terminal_error: Mutex<Option<String>>,
}

impl CallbackBridge {
    fn take_terminal_error(&self) -> Option<String> {
        self.terminal_error
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .take()
    }
}

impl HostBridge for CallbackBridge {
    fn call_tool(&self, name: &str, args_json: &str) -> pdsh_core::Result<String> {
        let Some(callback) = self.callbacks.call_tool else {
            return Err(Error::Bridge(format!(
                "no host bridge callback for tool {name}"
            )));
        };
        let tool_name = name.to_string();
        let name = CString::new(name)
            .map_err(|_| Error::Bridge("tool name contains a NUL byte".to_string()))?;
        let args = CString::new(args_json)
            .map_err(|_| Error::Bridge("tool arguments contain a NUL byte".to_string()))?;
        let mut capacity = INITIAL_TOOL_BUFFER;
        loop {
            let mut buffer = vec![0u8; capacity];
            let written = unsafe {
                callback(
                    self.user.0,
                    name.as_ptr(),
                    args.as_ptr(),
                    buffer.as_mut_ptr(),
                    buffer.len(),
                )
            };
            if written >= 0 {
                let length = usize::try_from(written)
                    .map_err(|_| Error::Bridge("host returned a negative size".to_string()))?;
                if length > buffer.len() {
                    return Err(Error::Bridge(format!(
                        "host returned {length} bytes into a {} byte buffer",
                        buffer.len()
                    )));
                }
                buffer.truncate(length);
                return String::from_utf8(buffer)
                    .map_err(|error| Error::Bridge(format!("tool result is not UTF-8: {error}")));
            }
            let needed = written
                .checked_neg()
                .ok_or_else(|| Error::Bridge("host reported an invalid size".to_string()))?
                as usize;
            if needed <= capacity {
                // A terminal failure, not a retry request. The host callback
                // returns -1 for a failed, cancelled or deadline-expired call;
                // the token tells the three apart for the diagnostic.
                let reason = if self.cancel.is_deadline_expired() {
                    "host tool bridge did not answer before the execution deadline"
                } else if self.cancel.is_cancelled() {
                    "host tool bridge call was cancelled"
                } else {
                    "host tool bridge call failed"
                };
                *self
                    .terminal_error
                    .lock()
                    .unwrap_or_else(|poison| poison.into_inner()) =
                    Some(format!("{tool_name}: {reason}\n"));
                return Err(Error::Bridge(reason.to_string()));
            }
            if needed > MAX_TOOL_RESULT_BYTES {
                return Err(Error::Bridge(format!(
                    "tool result needs {needed} bytes, over the {MAX_TOOL_RESULT_BYTES} byte limit"
                )));
            }
            capacity = needed;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::AtomicU64;
    use std::sync::Mutex;

    const HEADER: &str = include_str!("../../../include/xzshell.h");
    const EXPORTED_SYMBOLS: [&str; 7] = [
        "pdsh_cancel",
        "pdsh_caps_json",
        "pdsh_caps_json_with_bridge",
        "pdsh_join",
        "pdsh_monotonic_nanos",
        "pdsh_run",
        "pdsh_version",
    ];

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    struct TestTree {
        root: PathBuf,
    }

    impl TestTree {
        fn new(tag: &str) -> Self {
            let unique = COUNTER.fetch_add(1, Ordering::SeqCst);
            let root = std::env::temp_dir().join(format!(
                "pdsh-ffi-{}-{}-{}",
                std::process::id(),
                unique,
                tag
            ));
            fs::create_dir_all(root.join("workspace")).unwrap();
            fs::create_dir_all(root.join("home")).unwrap();
            TestTree { root }
        }

        fn workspace(&self) -> PathBuf {
            self.root.join("workspace")
        }

        fn home(&self) -> PathBuf {
            self.root.join("home")
        }
    }

    impl Drop for TestTree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[derive(Default)]
    struct Capture {
        stdout: Mutex<Vec<u8>>,
        stderr: Mutex<Vec<u8>>,
        exit: Mutex<Option<i32>>,
    }

    unsafe extern "C" fn capture_stdout(user: *mut c_void, ptr: *const u8, len: usize) {
        if ptr.is_null() || len == 0 {
            return;
        }
        let capture = &*(user as *const Capture);
        let bytes = std::slice::from_raw_parts(ptr, len);
        capture
            .stdout
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .extend_from_slice(bytes);
    }

    unsafe extern "C" fn capture_stderr(user: *mut c_void, ptr: *const u8, len: usize) {
        if ptr.is_null() || len == 0 {
            return;
        }
        let capture = &*(user as *const Capture);
        let bytes = std::slice::from_raw_parts(ptr, len);
        capture
            .stderr
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .extend_from_slice(bytes);
    }

    unsafe extern "C" fn capture_exit(user: *mut c_void, code: i32) {
        let capture = &*(user as *const Capture);
        *capture
            .exit
            .lock()
            .unwrap_or_else(|poison| poison.into_inner()) = Some(code);
    }

    unsafe extern "C" fn tool_echo(
        _user: *mut c_void,
        name: *const c_char,
        args_json: *const c_char,
        out_buf: *mut u8,
        out_cap: usize,
    ) -> isize {
        if name.is_null() || args_json.is_null() {
            return -1;
        }
        let name = CStr::from_ptr(name).to_str().unwrap_or("");
        let args = CStr::from_ptr(args_json).to_str().unwrap_or("");
        let payload = format!("{{\"name\":\"{name}\",\"args\":{args}}}");
        let bytes = payload.as_bytes();
        if out_buf.is_null() || out_cap < bytes.len() {
            return -(bytes.len() as isize);
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_buf, bytes.len());
        bytes.len() as isize
    }

    unsafe extern "C" fn tool_large(
        _user: *mut c_void,
        _name: *const c_char,
        _args_json: *const c_char,
        out_buf: *mut u8,
        out_cap: usize,
    ) -> isize {
        let needed = 10_000usize;
        if out_buf.is_null() || out_cap < needed {
            return -(needed as isize);
        }
        let mut payload = vec![b' '; needed];
        payload[0] = b'"';
        payload[needed - 1] = b'"';
        std::ptr::copy_nonoverlapping(payload.as_ptr(), out_buf, needed);
        needed as isize
    }

    unsafe extern "C" fn tool_fail(
        _user: *mut c_void,
        _name: *const c_char,
        _args_json: *const c_char,
        _out_buf: *mut u8,
        _out_cap: usize,
    ) -> isize {
        -1
    }

    fn limits() -> XzLimits {
        XzLimits {
            timeout_ms: 0,
            max_output_bytes: 1_048_576,
            max_files: 100,
            max_file_bytes: 1_048_576,
        }
    }

    /// A request whose backing strings outlive the call.
    struct RequestFixture {
        _argv: Vec<CString>,
        _argv_pointers: Vec<*const c_char>,
        _cwd: CString,
        _guest: CString,
        _host: CString,
        _guest_home: CString,
        _host_home: CString,
        _mounts: Vec<XzMount>,
        request: XzRequest,
    }

    impl RequestFixture {
        fn new(tree: &TestTree, argv: &[&str], limits: XzLimits) -> Self {
            let argv_owned: Vec<CString> = argv
                .iter()
                .map(|item| CString::new(*item).expect("argument"))
                .collect();
            let argv_pointers: Vec<*const c_char> =
                argv_owned.iter().map(|item| item.as_ptr()).collect();
            let cwd = CString::new("/dsh/workspace").unwrap();
            let guest = CString::new("/dsh/workspace").unwrap();
            let host = CString::new(tree.workspace().to_str().unwrap()).unwrap();
            let guest_home = CString::new("/dsh/home").unwrap();
            let host_home = CString::new(tree.home().to_str().unwrap()).unwrap();
            let mounts = vec![
                XzMount {
                    guest: guest.as_ptr(),
                    host: host.as_ptr(),
                },
                XzMount {
                    guest: guest_home.as_ptr(),
                    host: host_home.as_ptr(),
                },
            ];
            let request = XzRequest {
                argc: argv_pointers.len(),
                argv: argv_pointers.as_ptr(),
                cwd: cwd.as_ptr(),
                env_count: 0,
                env: std::ptr::null(),
                mount_count: mounts.len(),
                mounts: mounts.as_ptr(),
                limits,
                request_start_nanos: 0,
            };
            RequestFixture {
                _argv: argv_owned,
                _argv_pointers: argv_pointers,
                _cwd: cwd,
                _guest: guest,
                _host: host,
                _guest_home: guest_home,
                _host_home: host_home,
                _mounts: mounts,
                request,
            }
        }
    }

    fn callbacks(call_tool: XzCallToolCallback) -> XzCallbacks {
        XzCallbacks {
            on_stdout: Some(capture_stdout),
            on_stderr: Some(capture_stderr),
            on_exit: Some(capture_exit),
            call_tool,
        }
    }

    fn run(argv: &[&str], limits: XzLimits) -> (i32, Capture) {
        let tree = TestTree::new("run");
        let fixture = RequestFixture::new(&tree, argv, limits);
        let capture = Capture::default();
        let callbacks = callbacks(None);
        let handle = unsafe {
            pdsh_run(
                &fixture.request,
                &callbacks,
                &capture as *const Capture as *mut c_void,
            )
        };
        assert!(handle > 0, "pdsh_run returned {handle}");
        let code = pdsh_join(handle);
        (code, capture)
    }

    #[test]
    fn version_is_the_crate_version() {
        let version = unsafe { CStr::from_ptr(pdsh_version()) }
            .to_str()
            .expect("version is UTF-8");
        assert_eq!(version, env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn caps_json_queries_writes_and_rejects_short_buffers() {
        let needed = unsafe { pdsh_caps_json(std::ptr::null_mut(), 0) };
        assert!(needed > 0);
        let mut buffer = vec![0u8; needed as usize + 1];
        let written = unsafe { pdsh_caps_json(buffer.as_mut_ptr(), buffer.len()) };
        assert_eq!(written, needed);
        let text = unsafe { CStr::from_ptr(buffer.as_ptr() as *const c_char) }
            .to_str()
            .unwrap();
        assert!(text.starts_with("{\"accelerators\":["));
        assert!(text.contains("\"version\""));
        assert!(text.contains("\"limits\""));
        assert!(text.contains("\"max_output_bytes\""));
        // The complete production registry is linked, not just the core
        // diagnostics.
        for name in ["ctx", "jaq", "jq", "phone", "rg", "ts-parse", "ts-query"] {
            assert!(text.contains(&format!("\"{name}\"")), "missing {name}: {text}");
        }
        assert!(!text.contains("\"echo\""));
        assert!(!text.contains("\"pdsh-caps\""));

        let mut short = [0u8; 2];
        let negative = unsafe { pdsh_caps_json(short.as_mut_ptr(), short.len()) };
        assert_eq!(negative, -needed);
        assert_eq!(short, [0u8; 2]);

        // Without a host bridge the command that cannot run must not be
        // advertised either.
        let without_bridge = unsafe { pdsh_caps_json_with_bridge(0, std::ptr::null_mut(), 0) };
        let mut buffer = vec![0u8; without_bridge as usize];
        assert_eq!(
            unsafe { pdsh_caps_json_with_bridge(0, buffer.as_mut_ptr(), buffer.len()) },
            without_bridge
        );
        let text = String::from_utf8(buffer).unwrap();
        assert!(!text.contains("\"phone\""));
        assert!(!text.contains("\"ctx\""));
        for name in ["jaq", "jq", "rg", "ts-parse", "ts-query"] {
            assert!(text.contains(&format!("\"{name}\"")), "missing {name}: {text}");
        }
    }

    #[test]
    fn ffi_round_trip_collects_stdout_and_exit() {
        let (code, capture) = run(&["echo", "hello", "ffi"], limits());
        assert_eq!(code, 0);
        assert_eq!(*capture.stdout.lock().unwrap(), b"hello ffi\n");
        assert!(capture.stderr.lock().unwrap().is_empty());
        assert_eq!(*capture.exit.lock().unwrap(), Some(0));
    }

    #[test]
    fn ffi_output_is_truncated_before_the_callback() {
        let mut request_limits = limits();
        request_limits.max_output_bytes = 100;
        let (code, capture) = run(
            &["echo", "--repeat", "1000", "0123456789"],
            request_limits,
        );
        assert_eq!(code, 0);
        let stdout = capture.stdout.lock().unwrap().clone();
        let text = String::from_utf8(stdout).unwrap();
        assert!(text.contains("truncated"));
        assert!(text.starts_with("0123456789"));
    }

    #[test]
    fn ffi_reports_an_unknown_command() {
        let (code, capture) = run(&["definitely-not-a-command"], limits());
        assert_eq!(code, EXIT_UNKNOWN_COMMAND);
        let stderr = String::from_utf8(capture.stderr.lock().unwrap().clone()).unwrap();
        assert!(stderr.contains("unknown command"));
        assert_eq!(*capture.exit.lock().unwrap(), Some(EXIT_UNKNOWN_COMMAND));
    }

    #[test]
    fn ffi_cancel_returns_130() {
        let tree = TestTree::new("cancel");
        let fixture = RequestFixture::new(
            &tree,
            &["echo", "--repeat", "1000000000", "tick"],
            XzLimits {
                max_output_bytes: 1024,
                ..limits()
            },
        );
        let capture = Capture::default();
        let callbacks = callbacks(None);
        let handle = unsafe {
            pdsh_run(
                &fixture.request,
                &callbacks,
                &capture as *const Capture as *mut c_void,
            )
        };
        assert!(handle > 0);
        // Let the echo loop run for a moment so this cancels a live command
        // rather than only observing a pre-cancelled token.
        std::thread::sleep(Duration::from_millis(10));
        assert_eq!(pdsh_cancel(handle), 0);
        let code = pdsh_join(handle);
        assert_eq!(code, 130);
        assert_eq!(*capture.exit.lock().unwrap(), Some(130));
        assert_eq!(pdsh_cancel(handle), -1);
        assert_eq!(pdsh_join(handle), -1);
    }

    #[test]
    fn ffi_timeout_returns_124() {
        let tree = TestTree::new("timeout");
        let fixture = RequestFixture::new(
            &tree,
            &["echo", "--repeat", "1000000000", "tick"],
            XzLimits {
                timeout_ms: 5,
                max_output_bytes: 1024,
                ..limits()
            },
        );
        let capture = Capture::default();
        let callbacks = callbacks(None);
        let handle = unsafe {
            pdsh_run(
                &fixture.request,
                &callbacks,
                &capture as *const Capture as *mut c_void,
            )
        };
        assert!(handle > 0);
        assert_eq!(pdsh_join(handle), EXIT_TIMED_OUT);
    }

    #[test]
    fn ffi_panic_is_contained_and_reported() {
        let (code, capture) = run(&["pdsh-panic"], limits());
        assert_eq!(code, EXIT_PANIC);
        let stderr = String::from_utf8(capture.stderr.lock().unwrap().clone()).unwrap();
        assert!(stderr.contains("pdsh-shell: panic:"));
        assert!(stderr.contains("intentional test panic"));
        assert_eq!(*capture.exit.lock().unwrap(), Some(EXIT_PANIC));
    }

    #[test]
    fn ffi_rejects_invalid_pointers_and_requests() {
        assert_eq!(
            unsafe { pdsh_run(std::ptr::null(), std::ptr::null(), std::ptr::null_mut()) },
            -1
        );
        let request = XzRequest {
            argc: 0,
            argv: std::ptr::null(),
            cwd: std::ptr::null(),
            env_count: 0,
            env: std::ptr::null(),
            mount_count: 0,
            mounts: std::ptr::null(),
            limits: limits(),
            request_start_nanos: 0,
        };
        let callbacks = callbacks(None);
        assert_eq!(
            unsafe { pdsh_run(&request, &callbacks, std::ptr::null_mut()) },
            -1
        );
        assert_eq!(
            unsafe { pdsh_run(&request, std::ptr::null(), std::ptr::null_mut()) },
            -1
        );
    }

    #[test]
    fn ffi_rejects_a_relative_cwd_and_a_missing_mount() {
        let tree = TestTree::new("invalid");
        let mut fixture = RequestFixture::new(&tree, &["echo", "x"], limits());
        let relative = CString::new("relative/path").unwrap();
        fixture.request.cwd = relative.as_ptr();
        let capture = Capture::default();
        let callbacks = callbacks(None);
        assert_eq!(
            unsafe {
                pdsh_run(
                    &fixture.request,
                    &callbacks,
                    &capture as *const Capture as *mut c_void,
                )
            },
            -1
        );
        fixture.request.cwd = fixture._cwd.as_ptr();
        fixture.request.mount_count = 0;
        assert_eq!(
            unsafe {
                pdsh_run(
                    &fixture.request,
                    &callbacks,
                    &capture as *const Capture as *mut c_void,
                )
            },
            -1
        );
        drop(relative);
    }

    #[test]
    fn ffi_validates_argv_env_mounts_and_callbacks() {
        let tree = TestTree::new("validate");
        let callbacks = callbacks(None);
        let capture = Capture::default();

        // A NULL argv entry.
        let mut fixture = RequestFixture::new(&tree, &["echo", "x"], limits());
        let saved = fixture._argv_pointers[1];
        fixture._argv_pointers[1] = std::ptr::null();
        assert_eq!(
            unsafe {
                pdsh_run(
                    &fixture.request,
                    &callbacks,
                    &capture as *const Capture as *mut c_void,
                )
            },
            -1
        );
        fixture._argv_pointers[1] = saved;

        // A non-UTF-8 argument.
        let invalid = CString::new(vec![0xffu8]).unwrap();
        fixture._argv_pointers[1] = invalid.as_ptr();
        assert_eq!(
            unsafe {
                pdsh_run(
                    &fixture.request,
                    &callbacks,
                    &capture as *const Capture as *mut c_void,
                )
            },
            -1
        );
        fixture._argv_pointers[1] = saved;

        // A NULL callbacks object with an otherwise valid request.
        assert_eq!(
            unsafe {
                pdsh_run(
                    &fixture.request,
                    std::ptr::null(),
                    &capture as *const Capture as *mut c_void,
                )
            },
            -1
        );

        // An environment key that contains '='.
        let key = CString::new("BAD=KEY").unwrap();
        let value = CString::new("v").unwrap();
        let pair = XzEnvPair {
            key: key.as_ptr(),
            value: value.as_ptr(),
        };
        fixture.request.env_count = 1;
        fixture.request.env = &pair;
        assert_eq!(
            unsafe {
                pdsh_run(
                    &fixture.request,
                    &callbacks,
                    &capture as *const Capture as *mut c_void,
                )
            },
            -1
        );
        fixture.request.env_count = 0;
        fixture.request.env = std::ptr::null();

        // A cwd outside every mount.
        let outside = CString::new("/etc").unwrap();
        fixture.request.cwd = outside.as_ptr();
        assert_eq!(
            unsafe {
                pdsh_run(
                    &fixture.request,
                    &callbacks,
                    &capture as *const Capture as *mut c_void,
                )
            },
            -1
        );
        fixture.request.cwd = fixture._cwd.as_ptr();

        // A mount whose host directory does not exist.
        let guest = CString::new("/dsh/workspace").unwrap();
        let missing = CString::new(tree.root.join("missing").to_str().unwrap()).unwrap();
        let bad_mount = XzMount {
            guest: guest.as_ptr(),
            host: missing.as_ptr(),
        };
        fixture.request.mount_count = 1;
        fixture.request.mounts = &bad_mount;
        assert_eq!(
            unsafe {
                pdsh_run(
                    &fixture.request,
                    &callbacks,
                    &capture as *const Capture as *mut c_void,
                )
            },
            -1
        );
    }

    #[test]
    fn call_tool_forwards_name_and_arguments() {
        let callbacks = callbacks(Some(tool_echo));
        let bridge = CallbackBridge {
            callbacks,
            user: UserPtr(std::ptr::null_mut()),
            cancel: CancelToken::new(),
            terminal_error: Mutex::new(None),
        };
        let result = bridge.call_tool("phone", "{\"a\":1}").unwrap();
        assert_eq!(result, "{\"name\":\"phone\",\"args\":{\"a\":1}}");
    }

    #[test]
    fn call_tool_retries_with_a_larger_buffer() {
        let callbacks = callbacks(Some(tool_large));
        let bridge = CallbackBridge {
            callbacks,
            user: UserPtr(std::ptr::null_mut()),
            cancel: CancelToken::new(),
            terminal_error: Mutex::new(None),
        };
        let result = bridge.call_tool("ctx", "{}").unwrap();
        assert_eq!(result.len(), 10_000);
        assert!(result.starts_with('"'));
        assert!(result.ends_with('"'));
    }

    #[test]
    fn call_tool_without_a_callback_is_an_error() {
        let bridge = CallbackBridge {
            callbacks: callbacks(None),
            user: UserPtr(std::ptr::null_mut()),
            cancel: CancelToken::new(),
            terminal_error: Mutex::new(None),
        };
        assert!(matches!(
            bridge.call_tool("phone", "{}"),
            Err(Error::Bridge(_))
        ));
    }

    #[test]
    fn a_terminal_host_failure_reports_the_token_reason() {
        let callbacks = callbacks(Some(tool_fail));
        let bridge = CallbackBridge {
            callbacks,
            user: UserPtr(std::ptr::null_mut()),
            cancel: CancelToken::new(),
            terminal_error: Mutex::new(None),
        };
        let message = bridge.call_tool("phone", "{}").unwrap_err().to_string();
        assert!(message.contains("failed"), "{message}");

        let bridge = CallbackBridge {
            callbacks,
            user: UserPtr(std::ptr::null_mut()),
            cancel: CancelToken::new(),
            terminal_error: Mutex::new(None),
        };
        bridge.cancel.cancel();
        let message = bridge.call_tool("phone", "{}").unwrap_err().to_string();
        assert!(message.contains("cancelled"), "{message}");

        let bridge = CallbackBridge {
            callbacks,
            user: UserPtr(std::ptr::null_mut()),
            cancel: CancelToken::new(),
            terminal_error: Mutex::new(None),
        };
        bridge
            .cancel
            .set_deadline(Instant::now() - Duration::from_millis(1));
        let message = bridge.call_tool("phone", "{}").unwrap_err().to_string();
        assert!(message.contains("deadline"), "{message}");
    }

    fn header_symbols() -> Vec<String> {
        let mut names = Vec::new();
        for raw in HEADER.lines() {
            let line = raw.trim();
            if line.is_empty()
                || line.starts_with("/*")
                || line.starts_with('*')
                || line.starts_with("//")
                || line.starts_with('#')
            {
                continue;
            }
            let Some(open) = line.find('(') else {
                continue;
            };
            let before = &line[..open];
            let Some(start) = before
                .char_indices()
                .rev()
                .find(|(_, character)| !(character.is_ascii_alphanumeric() || *character == '_'))
                .map(|(index, character)| index + character.len_utf8())
            else {
                continue;
            };
            let name = before[start..].trim();
            if name.starts_with("pdsh_") {
                names.push(name.to_string());
            }
        }
        names.sort();
        names
    }

    fn source_symbols() -> Vec<String> {
        let mut names = Vec::new();
        for raw in include_str!("lib.rs").lines() {
            let line = raw.trim();
            for prefix in [
                "pub extern \"C\" fn ",
                "pub unsafe extern \"C\" fn ",
            ] {
                if let Some(rest) = line.strip_prefix(prefix) {
                    let name: String = rest
                        .chars()
                        .take_while(|character| {
                            character.is_ascii_alphanumeric() || *character == '_'
                        })
                        .collect();
                    if name.starts_with("pdsh_") {
                        names.push(name);
                    }
                }
            }
        }
        names.sort();
        names
    }

    #[test]
    fn header_matches_exports() {
        assert_eq!(header_symbols(), EXPORTED_SYMBOLS);
        assert_eq!(source_symbols(), EXPORTED_SYMBOLS);
    }
}
