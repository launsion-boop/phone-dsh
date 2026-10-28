// SPDX-License-Identifier: MIT
//! End-to-end tests of the C ABI the Swift host links.
//!
//! These call the exported `pdsh_*` functions exactly as the host does: the
//! tracked `pdsh-ffi` crate is linked against the production `pdsh-all`
//! registry, so the capability JSON, dispatch, host-bridge forwarding,
//! cancellation, deadline and output budget are exercised without a mock C
//! surface.

use std::ffi::{c_char, c_void, CStr, CString};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

use pdsh_ffi::{
    pdsh_cancel, pdsh_caps_json_with_bridge, pdsh_join, pdsh_monotonic_nanos, pdsh_run,
    XzCallToolCallback, XzCallbacks, XzEnvPair, XzLimits, XzMount, XzRequest,
};

static COUNTER: AtomicU64 = AtomicU64::new(0);

const EXPECTED_WITH_BRIDGE: [&str; 7] = ["ctx", "jaq", "jq", "phone", "rg", "ts-parse", "ts-query"];
const EXPECTED_WITHOUT_BRIDGE: [&str; 5] = ["jaq", "jq", "rg", "ts-parse", "ts-query"];

struct TestTree {
    root: PathBuf,
}

impl TestTree {
    fn new(tag: &str) -> TestTree {
        let root = std::env::temp_dir().join(format!(
            "pdsh-ffi-native-{}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst),
            tag
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("workspace")).unwrap();
        fs::create_dir_all(root.join("home")).unwrap();
        TestTree { root }
    }

    fn workspace(&self) -> PathBuf {
        self.root.join("workspace")
    }

    fn write(&self, relative: &str, contents: &str) {
        let path = self.workspace().join(relative);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, contents).unwrap();
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

impl Capture {
    fn stdout_text(&self) -> String {
        String::from_utf8_lossy(&self.stdout.lock().unwrap()).into_owned()
    }

    fn stderr_text(&self) -> String {
        String::from_utf8_lossy(&self.stderr.lock().unwrap()).into_owned()
    }
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

unsafe extern "C" fn tool_fail(
    _user: *mut c_void,
    _name: *const c_char,
    _args_json: *const c_char,
    _out_buf: *mut u8,
    _out_cap: usize,
) -> isize {
    -1
}

/// User state for the blocking-bridge tests. The capture lives here so the
/// same pointer reaches the output/exit callbacks and `call_tool`.
struct BridgeUser {
    capture: Capture,
    entered: Mutex<bool>,
    entered_event: Condvar,
    released: Mutex<bool>,
    release: Condvar,
}

impl Default for BridgeUser {
    fn default() -> BridgeUser {
        BridgeUser {
            capture: Capture::default(),
            entered: Mutex::new(false),
            entered_event: Condvar::new(),
            released: Mutex::new(false),
            release: Condvar::new(),
        }
    }
}

impl BridgeUser {
    fn mark_bridge_entered(&self) {
        *self
            .entered
            .lock()
            .unwrap_or_else(|poison| poison.into_inner()) = true;
        self.entered_event.notify_all();
    }

    /// Wait until the worker is really inside `call_tool`. Tests that cancel or
    /// let a deadline expire must not rely on a sleep to hit that window.
    fn wait_until_bridge_entered(&self) {
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut entered = self
            .entered
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        while !*entered {
            let now = Instant::now();
            assert!(
                now < deadline,
                "the worker did not enter the host bridge callback"
            );
            let (guard, _) = self
                .entered_event
                .wait_timeout(entered, deadline - now)
                .unwrap_or_else(|poison| poison.into_inner());
            entered = guard;
        }
    }

    fn release_bridge(&self) {
        *self
            .released
            .lock()
            .unwrap_or_else(|poison| poison.into_inner()) = true;
        self.release.notify_all();
    }
}

unsafe extern "C" fn bridge_stdout(user: *mut c_void, ptr: *const u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    let capture = &(*(user as *const BridgeUser)).capture;
    let bytes = std::slice::from_raw_parts(ptr, len);
    capture
        .stdout
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .extend_from_slice(bytes);
}

unsafe extern "C" fn bridge_stderr(user: *mut c_void, ptr: *const u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    let capture = &(*(user as *const BridgeUser)).capture;
    let bytes = std::slice::from_raw_parts(ptr, len);
    capture
        .stderr
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .extend_from_slice(bytes);
}

unsafe extern "C" fn bridge_exit(user: *mut c_void, code: i32) {
    let capture = &(*(user as *const BridgeUser)).capture;
    *capture
        .exit
        .lock()
        .unwrap_or_else(|poison| poison.into_inner()) = Some(code);
}

/// Records that the host bridge was entered and returns a terminal failure
/// immediately. Used to prove a callback that should already be expired is
/// never called.
unsafe extern "C" fn tool_mark_entered(
    user: *mut c_void,
    _name: *const c_char,
    _args_json: *const c_char,
    _out_buf: *mut u8,
    _out_cap: usize,
) -> isize {
    let user = &*(user as *const BridgeUser);
    user.mark_bridge_entered();
    -1
}

/// A host callback that never answers until the test releases it, modelling an
/// injected bridge that does not observe its own cancellation signal.
unsafe extern "C" fn tool_wait_for_release(
    user: *mut c_void,
    _name: *const c_char,
    _args_json: *const c_char,
    _out_buf: *mut u8,
    _out_cap: usize,
) -> isize {
    let user = &*(user as *const BridgeUser);
    user.mark_bridge_entered();
    let mut released = user
        .released
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    while !*released {
        released = user
            .release
            .wait(released)
            .unwrap_or_else(|poison| poison.into_inner());
    }
    -1
}

fn bridge_callbacks(call_tool: XzCallToolCallback) -> XzCallbacks {
    XzCallbacks {
        on_stdout: Some(bridge_stdout),
        on_stderr: Some(bridge_stderr),
        on_exit: Some(bridge_exit),
        call_tool,
    }
}

fn limits() -> XzLimits {
    XzLimits {
        timeout_ms: 0,
        max_output_bytes: 1_048_576,
        max_files: 100,
        max_file_bytes: 1_048_576,
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

fn caps_json(has_tool_bridge: bool) -> String {
    let needed =
        unsafe { pdsh_caps_json_with_bridge(has_tool_bridge as i32, std::ptr::null_mut(), 0) };
    assert!(needed > 0);
    let mut buffer = vec![0u8; needed as usize];
    let written = unsafe {
        pdsh_caps_json_with_bridge(has_tool_bridge as i32, buffer.as_mut_ptr(), buffer.len())
    };
    assert_eq!(written, needed);
    String::from_utf8(buffer).unwrap()
}

/// A request whose backing strings outlive the call and `pdsh_join`.
struct RequestFixture {
    _argv: Vec<CString>,
    _argv_pointers: Vec<*const c_char>,
    _cwd: CString,
    _env_keys: Vec<CString>,
    _env_values: Vec<CString>,
    _env_pairs: Vec<XzEnvPair>,
    _guest: CString,
    _host: CString,
    _guest_home: CString,
    _host_home: CString,
    _mounts: Vec<XzMount>,
    request: XzRequest,
}

impl RequestFixture {
    fn new(tree: &TestTree, argv: &[&str], limits: XzLimits) -> RequestFixture {
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
        let host_home = CString::new(tree.root.join("home").to_str().unwrap()).unwrap();
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
            _env_keys: Vec::new(),
            _env_values: Vec::new(),
            _env_pairs: Vec::new(),
            _guest: guest,
            _host: host,
            _guest_home: guest_home,
            _host_home: host_home,
            _mounts: mounts,
            request,
        }
    }

    /// Attach environment pairs and point the request at their stable heap
    /// storage. Used to make the synchronous `pdsh_run` parse outlive a short
    /// request budget.
    fn with_env(mut self, entries: &[(String, String)]) -> RequestFixture {
        self._env_keys = entries
            .iter()
            .map(|(key, _)| CString::new(key.as_str()).expect("env key"))
            .collect();
        self._env_values = entries
            .iter()
            .map(|(_, value)| CString::new(value.as_str()).expect("env value"))
            .collect();
        self._env_pairs = self
            ._env_keys
            .iter()
            .zip(self._env_values.iter())
            .map(|(key, value)| XzEnvPair {
                key: key.as_ptr(),
                value: value.as_ptr(),
            })
            .collect();
        self.request.env_count = self._env_pairs.len();
        self.request.env = self._env_pairs.as_ptr();
        self
    }

    fn run(&self, call_tool: XzCallToolCallback) -> (i32, Capture) {
        let capture = Capture::default();
        let callbacks = callbacks(call_tool);
        let handle = unsafe {
            pdsh_run(
                &self.request,
                &callbacks,
                &capture as *const Capture as *mut c_void,
            )
        };
        assert!(handle > 0, "pdsh_run returned {handle}");
        let code = pdsh_join(handle);
        (code, capture)
    }

    /// Start a job whose callbacks write into `capture`, which the caller
    /// keeps at one address until `pdsh_join` returns.
    fn start(&self, capture: &Capture, call_tool: XzCallToolCallback) -> i32 {
        let callbacks = callbacks(call_tool);
        let handle = unsafe {
            pdsh_run(
                &self.request,
                &callbacks,
                capture as *const Capture as *mut c_void,
            )
        };
        assert!(handle > 0, "pdsh_run returned {handle}");
        handle
    }
}

#[test]
fn caps_are_the_linked_production_registry() {
    let text = caps_json(true);
    for name in EXPECTED_WITH_BRIDGE {
        assert!(
            text.contains(&format!("\"{name}\"")),
            "missing {name}: {text}"
        );
    }
    assert!(!text.contains("\"echo\""));
    assert!(!text.contains("\"pdsh-caps\""));

    let without_bridge = caps_json(false);
    for name in EXPECTED_WITHOUT_BRIDGE {
        assert!(
            without_bridge.contains(&format!("\"{name}\"")),
            "missing {name}: {without_bridge}"
        );
    }
    for name in ["phone", "ctx"] {
        assert!(
            !without_bridge.contains(&format!("\"{name}\"")),
            "{name} must not be advertised without a host bridge: {without_bridge}"
        );
    }
}

#[test]
fn production_accelerators_run_through_the_c_abi() {
    let tree = TestTree::new("run");
    tree.write("a.txt", "alpha\nneedle here\n");
    tree.write("in.json", "{\"a\":1}\n");
    tree.write("a.rs", "fn main() {}\n");

    let fixture = RequestFixture::new(&tree, &["rg", "--json", "needle"], limits());
    let (code, capture) = fixture.run(None);
    assert_eq!(code, 0, "stderr: {}", capture.stderr_text());
    assert!(capture.stdout_text().contains("\"type\":\"match\""));
    assert!(capture.stdout_text().contains("needle"));

    let fixture = RequestFixture::new(&tree, &["jaq", "-c", ".a", "in.json"], limits());
    let (code, capture) = fixture.run(None);
    assert_eq!(code, 0, "stderr: {}", capture.stderr_text());
    assert_eq!(capture.stdout_text().trim(), "1");

    let fixture = RequestFixture::new(&tree, &["ts-parse", "a.rs"], limits());
    let (code, capture) = fixture.run(None);
    assert_eq!(code, 0, "stderr: {}", capture.stderr_text());
    assert!(capture.stdout_text().starts_with("(source_file "));
}

#[test]
fn phone_and_ctx_require_a_host_bridge() {
    let tree = TestTree::new("bridge");

    // Without the callback the commands are not in the run registry, matching
    // the bridge-less capability JSON above.
    let phone = ["phone", "contacts.search", "{\"q\":\"ann\"}"];
    let ctx = ["ctx", "weather", "in", "Oslo"];
    for argv in [phone.as_slice(), ctx.as_slice()] {
        let fixture = RequestFixture::new(&tree, &argv, limits());
        let (code, capture) = fixture.run(None);
        assert_eq!(code, 127, "stderr: {}", capture.stderr_text());
        assert!(capture.stderr_text().contains("unknown command"));
    }

    let fixture = RequestFixture::new(&tree, &phone, limits());
    let (code, capture) = fixture.run(Some(tool_echo));
    assert_eq!(code, 0, "stderr: {}", capture.stderr_text());
    assert!(capture.stdout_text().contains("phone.contacts.search"));
    assert!(capture.stdout_text().contains("\"q\":\"ann\""));

    let fixture = RequestFixture::new(&tree, &ctx, limits());
    let (code, capture) = fixture.run(Some(tool_echo));
    assert_eq!(code, 0, "stderr: {}", capture.stderr_text());
    assert!(capture.stdout_text().contains("ctx.query"));
    assert!(capture.stdout_text().contains("weather in Oslo"));
}

#[test]
fn output_budget_truncation_and_cancel_are_real_ffi_jobs() {
    let tree = TestTree::new("budget");
    let mut lines = String::new();
    for index in 0..500 {
        lines.push_str(&format!("needle line {index:03}\n"));
    }
    tree.write("big.txt", &lines);

    let fixture = RequestFixture::new(
        &tree,
        &["rg", "--json", "needle"],
        XzLimits {
            max_output_bytes: 128,
            ..limits()
        },
    );
    let (code, capture) = fixture.run(None);
    assert_eq!(code, 0, "stderr: {}", capture.stderr_text());
    let stdout = capture.stdout_text();
    assert!(stdout.contains("pdsh-shell truncated"), "{stdout}");
    assert!(stdout.len() < 4096);

    let fixture = RequestFixture::new(
        &tree,
        &["echo", "--repeat", "1000000000", "tick"],
        XzLimits {
            max_output_bytes: 1024,
            ..limits()
        },
    );
    let capture = Capture::default();
    let handle = fixture.start(&capture, None);
    std::thread::sleep(Duration::from_millis(10));
    assert_eq!(pdsh_cancel(handle), 0);
    assert_eq!(pdsh_join(handle), 130);
    assert_eq!(*capture.exit.lock().unwrap(), Some(130));
    assert_eq!(pdsh_cancel(handle), -1);
    assert_eq!(pdsh_join(handle), -1);

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
    let handle = fixture.start(&capture, None);
    assert_eq!(pdsh_join(handle), 124);
}

#[test]
fn a_failed_bridge_is_a_normal_exit_code() {
    let tree = TestTree::new("bridge-failure");
    let fixture = RequestFixture::new(&tree, &["phone", "missing.tool", "{}"], limits());
    let (code, capture) = fixture.run(Some(tool_fail));
    assert_eq!(code, 69, "stderr: {}", capture.stderr_text());
    assert!(capture.stderr_text().contains("phone.missing.tool"));
}

#[test]
fn a_cancelled_blocking_bridge_returns_130_with_a_cancel_diagnostic() {
    let tree = TestTree::new("bridge-cancel");
    let fixture = RequestFixture::new(&tree, &["phone", "slow.tool", "{}"], limits());
    let user = BridgeUser::default();
    let callbacks = bridge_callbacks(Some(tool_wait_for_release));
    let handle = unsafe {
        pdsh_run(
            &fixture.request,
            &callbacks,
            &user as *const BridgeUser as *mut c_void,
        )
    };
    assert!(handle > 0, "pdsh_run returned {handle}");
    // Wait for the worker to enter `call_tool`; this is the path under test.
    user.wait_until_bridge_entered();

    // pdsh_cancel sets the Rust token; releasing the host callback afterwards
    // lets the worker finish. A host that never releases still owns its
    // physical side effect, so the ABI reports cancellation only after the
    // callback returns.
    assert_eq!(pdsh_cancel(handle), 0);
    user.release_bridge();
    let joined = Instant::now();
    assert_eq!(pdsh_join(handle), 130);
    assert!(
        joined.elapsed() < Duration::from_secs(1),
        "join waited {:?} after the host callback was released",
        joined.elapsed()
    );
    assert_eq!(*user.capture.exit.lock().unwrap(), Some(130));
    let stderr = user.capture.stderr_text();
    assert!(stderr.contains("cancelled"), "stderr: {stderr}");
}

#[test]
fn request_start_is_charged_before_the_bridge_and_parse_can_expire_the_budget() {
    let tree = TestTree::new("bridge-original-budget");
    // A large environment makes the synchronous `pdsh_run` parse outlive the
    // 1 ms budget. The token is armed from the host-supplied request start
    // before that parse, so by the time the worker starts it is already
    // expired and the host bridge is never entered. The old behaviour armed a
    // fresh 1 ms deadline after the parse and would call the bridge here.
    let padding = "p".repeat(96);
    let entries: Vec<(String, String)> = (0..200_000)
        .map(|index| {
            (
                format!("PDSH_BRIDGE_START_{padding}_{index}"),
                format!("v{index}"),
            )
        })
        .collect();
    let mut fixture = RequestFixture::new(
        &tree,
        &["phone", "slow.tool", "{}"],
        XzLimits {
            timeout_ms: 1,
            ..limits()
        },
    )
    .with_env(&entries);
    fixture.request.request_start_nanos = pdsh_monotonic_nanos().max(1);
    let user = BridgeUser::default();
    let callbacks = bridge_callbacks(Some(tool_mark_entered));
    let started = Instant::now();
    let handle = unsafe {
        pdsh_run(
            &fixture.request,
            &callbacks,
            &user as *const BridgeUser as *mut c_void,
        )
    };
    assert!(handle > 0, "pdsh_run returned {handle}");
    assert_eq!(pdsh_join(handle), 124);
    assert!(
        started.elapsed() < Duration::from_secs(1),
        "an already expired request must not grant the bridge a fresh budget: {:?}",
        started.elapsed()
    );
    assert!(
        !*user
            .entered
            .lock()
            .unwrap_or_else(|poison| poison.into_inner()),
        "the host bridge must not be entered after the original request budget expired"
    );
}

#[test]
fn a_bridge_overrunning_the_deadline_returns_124_with_a_deadline_diagnostic() {
    let tree = TestTree::new("bridge-deadline");
    let fixture = RequestFixture::new(
        &tree,
        &["phone", "slow.tool", "{}"],
        XzLimits {
            timeout_ms: 500,
            ..limits()
        },
    );
    let user = BridgeUser::default();
    let callbacks = bridge_callbacks(Some(tool_wait_for_release));
    let handle = unsafe {
        pdsh_run(
            &fixture.request,
            &callbacks,
            &user as *const BridgeUser as *mut c_void,
        )
    };
    assert!(handle > 0, "pdsh_run returned {handle}");
    // Confirm the worker is blocked inside the bridge before the deadline can
    // expire. A 20 ms/10 ms sleep raced CI scheduling and could hit the plain
    // `check_cancel` path without a bridge diagnostic.
    user.wait_until_bridge_entered();
    std::thread::sleep(Duration::from_millis(600));
    user.release_bridge();
    let joined = Instant::now();
    assert_eq!(pdsh_join(handle), 124);
    assert!(
        joined.elapsed() < Duration::from_secs(1),
        "join waited {:?} after the host callback was released",
        joined.elapsed()
    );
    assert_eq!(*user.capture.exit.lock().unwrap(), Some(124));
    let stderr = user.capture.stderr_text();
    assert!(stderr.contains("deadline"), "stderr: {stderr}");
}

/// The initial sample is an execution start, never the legacy unset marker.
/// A child process gives this test a cold process-local monotonic epoch.
#[test]
fn first_monotonic_sample_is_not_the_unset_sentinel() {
    const CHILD: &str = "PDSH_FFI_FIRST_CLOCK_SAMPLE_CHILD";
    if std::env::var_os(CHILD).is_some() {
        let first = pdsh_monotonic_nanos();
        let next = pdsh_monotonic_nanos();
        assert!(first > 0, "first request must retain its pre-parse budget");
        assert!(next >= first);
        return;
    }
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "first_monotonic_sample_is_not_the_unset_sentinel", "--nocapture"])
        .env(CHILD, "1")
        .status()
        .expect("launch the isolated C ABI clock probe");
    assert!(status.success(), "cold-clock subprocess failed: {status}");
}
