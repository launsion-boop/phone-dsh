// SPDX-License-Identifier: MIT
//! The execution-surface read policy vs. the `jaq` accelerator.
//!
//! `jaq` is the second host accelerator the Worker can route to; it reads its
//! input files through the same [`pdsh_core::Vfs`] as `rg`. These tests pin the
//! same `EACCES` + one-sentence answer for the three DSH-internal roots and the
//! positive control (`/dsh/home/capabilities.json`).

mod common;

use std::fs;
use std::path::Path;

use common::{run, Fixture};
use pdsh_core::{exec_read_denied_message, EXEC_INTERNAL_ROOTS};

/// One fixture with a secret under every internal root and a readable manifest.
fn fixture(label: &str) -> Fixture {
    let fixture = Fixture::new(label);
    let home = fixture.root().join("home");
    for (relative, contents) in [
        ("sessions/project/session.v4.jsonl", "{\"secret\":true}\n"),
        ("storages/store.json", "{\"secret\":true}\n"),
        ("tool-journal/tool.jsonl", "{\"secret\":true}\n"),
        ("capabilities.json", "{\"capabilities\":true}\n"),
    ] {
        let path = home.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }
    fixture
}

fn args(items: &[&str]) -> Vec<String> {
    items.iter().map(|item| (*item).to_string()).collect()
}

fn expected(path: &str, root: &str) -> String {
    format!("EACCES: {}", exec_read_denied_message(Path::new(path), root))
}

#[test]
fn jaq_refuses_every_internal_root() {
    let fixture = fixture("jaq-policy-roots");
    for root in EXEC_INTERNAL_ROOTS {
        let output = run(&fixture, &args(&[".", root]));
        assert_ne!(output.code, 0, "{root} must fail");
        assert_eq!(output.stdout, "", "{root}: jaq printed DSH-internal bytes");
        assert_eq!(
            output.stderr.matches("EACCES: session-internal").count(),
            1,
            "{root}: exactly one denial line, got: {}",
            output.stderr
        );
        assert!(
            output.stderr.contains(&expected(root, root)),
            "{root}: the contract sentence is missing: {}",
            output.stderr
        );
        assert!(
            !output.stderr.contains("No such file or directory")
                && !output.stderr.contains("Permission denied"),
            "{root}: the denial must not be reworded: {}",
            output.stderr
        );
    }
}

#[test]
fn jaq_refuses_files_under_every_internal_root() {
    let fixture = fixture("jaq-policy-files");
    for file in [
        "/dsh/home/sessions/project/session.v4.jsonl",
        "/dsh/home/storages/store.json",
        "/dsh/home/tool-journal/tool.jsonl",
    ] {
        let output = run(&fixture, &args(&[".secret", file]));
        assert_ne!(output.code, 0, "{file} must fail");
        assert_eq!(output.stdout, "", "{file}: jaq printed the file bytes");
        let root = EXEC_INTERNAL_ROOTS
            .iter()
            .find(|root| file.starts_with(**root))
            .expect("the file is under a root");
        assert!(
            output.stderr.contains(&expected(file, root)),
            "{file}: the contract sentence is missing: {}",
            output.stderr
        );
    }
}

#[test]
fn capabilities_json_stays_readable() {
    let fixture = fixture("jaq-policy-allowed");
    let output = run(&fixture, &args(&[".capabilities", "/dsh/home/capabilities.json"]));
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(output.stdout, "true\n");
    assert_eq!(output.stderr, "");
}

#[test]
fn a_relative_spelling_is_refused_against_the_cwd() {
    let fixture = fixture("jaq-policy-relative");
    // jaq's input files are resolved by the Ctx cwd, so the same relative
    // operand a device script uses is refused with the canonical path.
    let output = run(&fixture, &args(&[".secret", "../home/sessions/project/session.v4.jsonl"]));
    assert_ne!(output.code, 0);
    assert_eq!(output.stdout, "");
    assert!(
        output.stderr.contains(&expected(
            "/dsh/home/sessions/project/session.v4.jsonl",
            "/dsh/home/sessions"
        )),
        "stderr: {}",
        output.stderr
    );
}
