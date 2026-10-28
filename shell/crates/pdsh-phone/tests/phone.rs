// SPDX-License-Identifier: MIT
//! `phone` / `ctx` tests with a recording host bridge.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use pdsh_core::{Command, Ctx, Error, HostBridge, Limits, StdFsVfs};
use pdsh_phone::{CtxCommand, PhoneCommand};

static COUNTER: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new(label: &str) -> Fixture {
        let mut root = std::env::temp_dir();
        root.push(format!(
            "pdsh-phone-{}-{}-{}",
            std::process::id(),
            label,
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("workspace")).unwrap();
        fs::create_dir_all(root.join("home")).unwrap();
        Fixture { root }
    }

    fn root(&self) -> &Path {
        &self.root
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// A bridge that records every call and returns a scripted result.
struct RecordingBridge {
    calls: Mutex<Vec<(String, String)>>,
    result: Result<String, String>,
}

impl RecordingBridge {
    fn ok(result: &str) -> RecordingBridge {
        RecordingBridge {
            calls: Mutex::new(Vec::new()),
            result: Ok(result.to_string()),
        }
    }

    fn failing(message: &str) -> RecordingBridge {
        RecordingBridge {
            calls: Mutex::new(Vec::new()),
            result: Err(message.to_string()),
        }
    }

    fn calls(&self) -> Vec<(String, String)> {
        self.calls.lock().unwrap().clone()
    }
}

impl HostBridge for RecordingBridge {
    fn call_tool(&self, name: &str, args_json: &str) -> pdsh_core::Result<String> {
        self.calls
            .lock()
            .unwrap()
            .push((name.to_string(), args_json.to_string()));
        match &self.result {
            Ok(result) => Ok(result.clone()),
            Err(message) => Err(Error::Bridge(message.clone())),
        }
    }
}

struct Run {
    code: i32,
    stdout: String,
    stderr: String,
}

fn run(
    fixture: &Fixture,
    bridge: &RecordingBridge,
    limits: Limits,
    command: &dyn Command,
    args: &[&str],
) -> Run {
    let vfs = StdFsVfs::for_root(fixture.root()).unwrap();
    let mut ctx = Ctx::new(&vfs, bridge, "/dsh/workspace", limits);
    let mut argv = vec![command.name().to_string()];
    argv.extend(args.iter().map(|argument| (*argument).to_string()));
    let code = command.run(&argv, &mut ctx);
    let (stdout, stderr) = ctx.finish();
    Run {
        code,
        stdout: String::from_utf8_lossy(&stdout.data).into_owned(),
        stderr: String::from_utf8_lossy(&stderr.data).into_owned(),
    }
}

fn default_run(
    fixture: &Fixture,
    bridge: &RecordingBridge,
    command: &dyn Command,
    args: &[&str],
) -> Run {
    run(fixture, bridge, Limits::default(), command, args)
}

#[test]
fn the_command_names_are_phone_and_ctx() {
    assert_eq!(PhoneCommand.name(), "phone");
    assert_eq!(CtxCommand.name(), "ctx");
}

#[test]
fn phone_calls_the_prefixed_tool_with_default_arguments() {
    let fixture = Fixture::new("phone-default");
    let bridge = RecordingBridge::ok("{\"ok\":true}");
    let output = default_run(&fixture, &bridge, &PhoneCommand, &["contacts.search"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(output.stdout, "{\"ok\":true}\n");
    assert_eq!(
        bridge.calls(),
        vec![("phone.contacts.search".to_string(), "{}".to_string())]
    );
}

#[test]
fn phone_passes_json_arguments_verbatim() {
    let fixture = Fixture::new("phone-args");
    let bridge = RecordingBridge::ok("[1,2]");
    let output = default_run(
        &fixture,
        &bridge,
        &PhoneCommand,
        &["contacts.search", "{\"q\":\"ann\"}"],
    );
    assert_eq!(output.code, 0);
    assert_eq!(output.stdout, "[1,2]\n");
    assert_eq!(
        bridge.calls(),
        vec![(
            "phone.contacts.search".to_string(),
            "{\"q\":\"ann\"}".to_string()
        )]
    );
}

#[test]
fn phone_rejects_missing_and_invalid_tools_without_calling_the_bridge() {
    let fixture = Fixture::new("phone-usage");
    let bridge = RecordingBridge::ok("{}");
    let output = default_run(&fixture, &bridge, &PhoneCommand, &[]);
    assert_eq!(output.code, 64);
    let output = default_run(&fixture, &bridge, &PhoneCommand, &["bad name"]);
    assert_eq!(output.code, 64);
    let output = default_run(&fixture, &bridge, &PhoneCommand, &["../escape"]);
    assert_eq!(output.code, 64);
    assert!(bridge.calls().is_empty());
}

#[test]
fn phone_rejects_invalid_json_arguments() {
    let fixture = Fixture::new("phone-bad-json");
    let bridge = RecordingBridge::ok("{}");
    let output = default_run(&fixture, &bridge, &PhoneCommand, &["contacts", "{oops"]);
    assert_eq!(output.code, 64);
    assert!(output.stderr.contains("invalid JSON"));
    assert!(bridge.calls().is_empty());
    let output = default_run(&fixture, &bridge, &PhoneCommand, &["contacts", "[1]"]);
    assert_eq!(output.code, 64);
    assert!(bridge.calls().is_empty());
}

#[test]
fn a_bridge_failure_maps_to_exit_69_with_the_message() {
    let fixture = Fixture::new("phone-bridge-error");
    let bridge = RecordingBridge::failing("tool unavailable");
    let output = default_run(&fixture, &bridge, &PhoneCommand, &["contacts"]);
    assert_eq!(output.code, 69);
    assert!(output.stderr.contains("tool unavailable"), "stderr: {}", output.stderr);
    assert!(output.stderr.contains("phone.contacts"));
    assert!(output.stdout.is_empty());
}

#[test]
fn ctx_calls_the_query_tool_with_a_joined_query() {
    let fixture = Fixture::new("ctx-query");
    let bridge = RecordingBridge::ok("\"sunny\"");
    let output = default_run(&fixture, &bridge, &CtxCommand, &["weather", "in", "Oslo"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(output.stdout, "\"sunny\"\n");
    assert_eq!(
        bridge.calls(),
        vec![(
            "ctx.query".to_string(),
            "{\"q\":\"weather in Oslo\"}".to_string()
        )]
    );
}

#[test]
fn ctx_escapes_the_query_as_json() {
    let fixture = Fixture::new("ctx-escape");
    let bridge = RecordingBridge::ok("null");
    let output = default_run(&fixture, &bridge, &CtxCommand, &["say \"hi\""]);
    assert_eq!(output.code, 0);
    let calls = bridge.calls();
    let args: serde_json::Value = serde_json::from_str(&calls[0].1).unwrap();
    assert_eq!(args["q"], "say \"hi\"");
}

#[test]
fn ctx_rejects_an_empty_query() {
    let fixture = Fixture::new("ctx-empty");
    let bridge = RecordingBridge::ok("null");
    let output = default_run(&fixture, &bridge, &CtxCommand, &[]);
    assert_eq!(output.code, 64);
    assert!(bridge.calls().is_empty());
}

#[test]
fn a_ctx_bridge_failure_also_maps_to_69() {
    let fixture = Fixture::new("ctx-bridge-error");
    let bridge = RecordingBridge::failing("no context provider");
    let output = default_run(&fixture, &bridge, &CtxCommand, &["time"]);
    assert_eq!(output.code, 69);
    assert!(output.stderr.contains("no context provider"));
}

#[test]
fn an_oversized_result_is_rejected_instead_of_truncated() {
    let fixture = Fixture::new("phone-oversize");
    let bridge = RecordingBridge::ok(&"x".repeat(200));
    let limits = Limits {
        max_output_bytes: 64,
        ..Limits::default()
    };
    let output = run(&fixture, &bridge, limits, &PhoneCommand, &["contacts"]);
    assert_eq!(output.code, 65);
    assert!(output.stdout.is_empty());
    assert!(output.stderr.contains("output budget"));
}

#[test]
fn the_result_gets_exactly_one_trailing_newline() {
    let fixture = Fixture::new("phone-newline");
    let bridge = RecordingBridge::ok("{\"a\":1}\n\n");
    let output = default_run(&fixture, &bridge, &PhoneCommand, &["contacts"]);
    assert_eq!(output.stdout, "{\"a\":1}\n");
}

#[test]
fn a_pre_cancelled_token_skips_the_bridge_and_returns_130() {
    let fixture = Fixture::new("phone-cancel");
    let bridge = RecordingBridge::ok("{}");
    let vfs = StdFsVfs::for_root(fixture.root()).unwrap();
    let token = pdsh_core::CancelToken::new();
    token.cancel();
    let mut ctx = Ctx::new(&vfs, &bridge, "/dsh/workspace", Limits::default())
        .with_cancel(token);
    let argv = vec!["phone".to_string(), "contacts".to_string()];
    let code = PhoneCommand.run(&argv, &mut ctx);
    assert_eq!(code, 130);
    assert!(bridge.calls().is_empty());
}

#[test]
fn help_is_successful() {
    let fixture = Fixture::new("phone-help");
    let bridge = RecordingBridge::ok("{}");
    let output = default_run(&fixture, &bridge, &PhoneCommand, &["--help"]);
    assert_eq!(output.code, 0);
    assert!(output.stdout.contains("USAGE"));
    assert!(bridge.calls().is_empty());
}
