// SPDX-License-Identifier: MIT
//! End-to-end registration tests for the complete accelerator registry.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use pdsh_all::{
    accelerator_names, accelerator_names_with_bridge, pdsh_shell_accelerators,
    pdsh_shell_accelerators_with_bridge,
};
use pdsh_core::{Ctx, Error, HostBridge, Limits, StdFsVfs};

static COUNTER: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new(label: &str) -> Fixture {
        let mut root = std::env::temp_dir();
        root.push(format!(
            "pdsh-all-{}-{}-{}",
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

    fn write(&self, relative: &str, contents: &str) {
        fs::write(self.root.join("workspace").join(relative), contents).unwrap();
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

struct FakeBridge {
    calls: Mutex<Vec<(String, String)>>,
}

impl FakeBridge {
    fn new() -> FakeBridge {
        FakeBridge {
            calls: Mutex::new(Vec::new()),
        }
    }
}

impl HostBridge for FakeBridge {
    fn call_tool(&self, name: &str, args_json: &str) -> pdsh_core::Result<String> {
        self.calls
            .lock()
            .unwrap()
            .push((name.to_string(), args_json.to_string()));
        Ok("{\"ok\":true}".to_string())
    }
}

fn run_with_bridge(
    fixture: &Fixture,
    bridge: &FakeBridge,
    argv: &[&str],
) -> (i32, String, String) {
    let registry = pdsh_shell_accelerators();
    let vfs = StdFsVfs::for_root(fixture.root()).unwrap();
    let mut ctx = Ctx::new(&vfs, bridge, "/dsh/workspace", Limits::default());
    let argv: Vec<String> = argv.iter().map(|item| (*item).to_string()).collect();
    let result = registry.run(&argv[0], &argv, &mut ctx);
    let (stdout, stderr) = ctx.finish();
    let code = match result {
        Ok(code) => code,
        Err(Error::Cancelled) => 130,
        Err(_) => 2,
    };
    (
        code,
        String::from_utf8_lossy(&stdout.data).into_owned(),
        String::from_utf8_lossy(&stderr.data).into_owned(),
    )
}

fn run(fixture: &Fixture, argv: &[&str]) -> (i32, String, String) {
    let bridge = FakeBridge::new();
    run_with_bridge(fixture, &bridge, argv)
}

#[test]
fn every_accelerator_is_registered_and_advertised() {
    let names = accelerator_names();
    assert_eq!(
        names,
        vec!["ctx", "jaq", "jq", "phone", "rg", "ts-parse", "ts-query"]
    );
}

#[test]
fn a_bridge_less_registry_does_not_register_or_advertise_phone_and_ctx() {
    let names = accelerator_names_with_bridge(false);
    assert_eq!(names, vec!["jaq", "jq", "rg", "ts-parse", "ts-query"]);
    let registry = pdsh_shell_accelerators_with_bridge(false);
    assert!(registry.get("phone").is_none());
    assert!(registry.get("ctx").is_none());
    let json = registry.caps_json(&Limits::default());
    assert!(!json.contains("\"phone\""));
    assert!(!json.contains("\"ctx\""));
    assert!(registry.get("rg").is_some());

    let with_bridge = pdsh_shell_accelerators_with_bridge(true);
    assert!(with_bridge.get("phone").is_some());
    assert!(with_bridge.get("ctx").is_some());
}

#[test]
fn the_registry_capability_json_lists_every_accelerator() {
    let registry = pdsh_shell_accelerators();
    let json = registry.caps_json(&Limits::default());
    for name in accelerator_names() {
        assert!(json.contains(&format!("\"{name}\"")), "missing {name}: {json}");
    }
    assert!(json.contains(&format!("\"version\":\"{}\"", pdsh_core::VERSION)));
    assert!(json.contains("\"max_file_bytes\":15728640"));
    // The unadvertised `echo` / `pdsh-caps` diagnostic commands are not part of
    // this registry at all.
    assert!(!json.contains("\"echo\""));
    assert!(!json.contains("\"pdsh-caps\""));
}

#[test]
fn the_registry_runs_rg_end_to_end() {
    let fixture = Fixture::new("rg");
    fixture.write("a.txt", "needle here\n");
    let (code, stdout, stderr) = run(&fixture, &["rg", "--json", "needle"]);
    assert_eq!(code, 0, "stderr: {stderr}");
    assert!(stdout.contains("\"type\":\"match\""));
    assert!(stdout.contains("\"text\":\"needle\""));
    assert!(stdout.contains("\"type\":\"summary\""));
}

#[test]
fn the_registry_runs_jaq_end_to_end() {
    let fixture = Fixture::new("jaq");
    fixture.write("in.json", "{\"a\":1}\n");
    let (code, stdout, stderr) = run(&fixture, &["jaq", ".a", "in.json"]);
    assert_eq!(code, 0, "stderr: {stderr}");
    assert_eq!(stdout, "1\n");
    let (code, stdout, stderr) = run(&fixture, &["jq", "--arg", "n", "2", ".a + 1", "in.json"]);
    assert_eq!(code, 0, "stderr: {stderr}");
    assert_eq!(stdout, "2\n");
}

#[test]
fn the_registry_runs_ts_parse_end_to_end() {
    let fixture = Fixture::new("ts");
    fixture.write("a.rs", "fn main() {}\n");
    let (code, stdout, stderr) = run(&fixture, &["ts-parse", "a.rs"]);
    assert_eq!(code, 0, "stderr: {stderr}");
    assert!(stdout.starts_with("(source_file "));
    let (code, stdout, stderr) = run(&fixture, &["ts-query", "--captures", "a.rs", "(identifier) @id"]);
    assert_eq!(code, 0, "stderr: {stderr}");
    assert!(stdout.contains("\"text\":\"main\""));
}

#[test]
fn the_registry_runs_phone_and_ctx_end_to_end() {
    let fixture = Fixture::new("phone");
    let bridge = FakeBridge::new();
    let (code, stdout, stderr) =
        run_with_bridge(&fixture, &bridge, &["phone", "contacts.search", "{\"q\":\"ann\"}"]);
    assert_eq!(code, 0, "stderr: {stderr}");
    assert_eq!(stdout, "{\"ok\":true}\n");
    let (code, stdout, stderr) = run_with_bridge(&fixture, &bridge, &["ctx", "weather", "in", "Oslo"]);
    assert_eq!(code, 0, "stderr: {stderr}");
    assert_eq!(stdout, "{\"ok\":true}\n");
    let calls = bridge.calls.lock().unwrap().clone();
    assert_eq!(calls[0].0, "phone.contacts.search");
    assert_eq!(calls[1].0, "ctx.query");
    assert_eq!(calls[1].1, "{\"q\":\"weather in Oslo\"}");
}

#[test]
fn unknown_commands_are_typed_errors() {
    let fixture = Fixture::new("unknown");
    let registry = pdsh_shell_accelerators();
    let vfs = StdFsVfs::for_root(fixture.root()).unwrap();
    let bridge = FakeBridge::new();
    let mut ctx = Ctx::new(&vfs, &bridge, "/dsh/workspace", Limits::default());
    let argv = vec!["bash".to_string()];
    let error = registry.run("bash", &argv, &mut ctx).unwrap_err();
    assert!(matches!(error, Error::UnknownCommand(name) if name == "bash"));
}

#[test]
fn there_is_no_writing_command_in_the_registry() {
    // The registry is the read-only accelerator set: a general shell, a writer
    // or an editor is never registered here (PLAN §2.4, D12).
    let names = accelerator_names();
    for forbidden in ["bash", "sh", "write", "edit", "rm", "mv", "cp", "touch"] {
        assert!(!names.iter().any(|name| name == forbidden), "{forbidden}");
    }
}
