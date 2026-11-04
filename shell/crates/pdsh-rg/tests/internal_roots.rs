// SPDX-License-Identifier: MIT
//! The execution-surface read policy vs. the `rg` accelerator.
//!
//! `channel.md` §6: `/dsh/home/{sessions,storages,tool-journal}/**` is
//! DSH-internal. `rg` runs in the host process, so the Worker's VFS wrapper
//! cannot see its reads; the refusal must come from the host data outlet. These
//! tests drive the real `run_rg` over the real `StdFsVfs`, i.e. the same path a
//! device EXEC_REQ takes, and assert the bytes never reach stdout.
//!
//! `/dsh/home/capabilities.json` is deliberately *not* internal state: the
//! positive control proves the guard is a root table, not a blanket refusal of
//! `/dsh/home`.

mod common;

use std::path::Path;

use common::{run, Fixture};
use pdsh_core::{exec_read_denied_message, EXEC_INTERNAL_ROOTS};

/// One fixture with a real secret in every internal root and two readable home
/// files, so a leak shows up in stdout and an over-broad guard shows up on the
/// positive control.
fn fixture(label: &str) -> Fixture {
    let fixture = Fixture::new(label);
    fixture.write_home("sessions/project/session.v4.jsonl", "{\"secret\":true}\n");
    fixture.write_home("storages/store.json", "{\"secret\":true}\n");
    fixture.write_home("tool-journal/tool.jsonl", "{\"secret\":true}\n");
    fixture.write_home("capabilities.json", "{\"capabilities\":true}\n");
    fixture.write_home("AGENTS.md", "public notes\n");
    fixture
}

/// The exact line the policy must produce for one refused path.
fn expected(path: &str, root: &str) -> String {
    format!("EACCES: {}", exec_read_denied_message(Path::new(path), root))
}

#[test]
fn rg_reads_no_bytes_from_any_internal_root() {
    let fixture = fixture("policy-roots");
    for root in EXEC_INTERNAL_ROOTS {
        let output = run(&fixture, "/dsh/workspace", &["-n", "secret", root]);
        assert_eq!(output.code, 2, "{root}: stderr: {}", output.stderr);
        assert_eq!(output.stdout, "", "{root}: rg printed DSH-internal bytes");
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
            "{root}: the denial must not be reworded as absence or a bare errno: {}",
            output.stderr
        );
    }
}

#[test]
fn rg_reads_no_bytes_from_a_file_under_an_internal_root() {
    let fixture = fixture("policy-files");
    for (root, file) in [
        (
            EXEC_INTERNAL_ROOTS[0],
            "/dsh/home/sessions/project/session.v4.jsonl",
        ),
        (EXEC_INTERNAL_ROOTS[1], "/dsh/home/storages/store.json"),
        (
            EXEC_INTERNAL_ROOTS[2],
            "/dsh/home/tool-journal/tool.jsonl",
        ),
    ] {
        let output = run(&fixture, "/dsh/workspace", &["-n", "secret", file]);
        assert_eq!(output.code, 2, "{file}: stderr: {}", output.stderr);
        assert_eq!(output.stdout, "", "{file}: rg printed the file bytes");
        assert!(
            output.stderr.contains(&expected(file, root)),
            "{file}: the contract sentence is missing: {}",
            output.stderr
        );
    }
}

#[test]
fn rg_files_never_walks_into_an_internal_root() {
    let fixture = fixture("policy-walk");
    let output = run(&fixture, "/dsh/workspace", &["--files", "/dsh/home"]);
    // Since the host's `read_dir` hides the three internal roots, the walker never
    // sees them: it cannot refuse what is not listed, so the run succeeds. The
    // guarantee is now stronger than "refuses with EACCES" — the names never
    // reach the accelerator at all, which is what the Worker's `ls` already did.
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    for root in EXEC_INTERNAL_ROOTS {
        assert!(
            !output.stdout.contains(root),
            "--files listed DSH-internal entries: {}",
            output.stdout
        );
        assert!(
            !output.stderr.contains(root),
            "--files named the hidden root {root} on stderr: {}",
            output.stderr
        );
    }
    // The readable sibling is still listed: the guard is not "refuse /dsh/home".
    assert!(
        output.stdout.contains("/dsh/home/capabilities.json"),
        "the walk must keep listing readable home files: {}",
        output.stdout
    );
    assert!(output.stdout.contains("/dsh/home/AGENTS.md"));
}

#[test]
fn rg_searches_from_the_home_root_without_leaking() {
    let fixture = fixture("policy-home-root");
    let output = run(&fixture, "/dsh/workspace", &["-n", "secret", "/dsh/home"]);
    // A search from the home root now finds nothing at all: the only `secret`
    // lives under an internal root, and `read_dir` does not return those, so the
    // walker never descends and never reports a refusal. Exit 1 ("no match") is
    // the honest outcome; the guarantee is that the name never appears.
    assert_eq!(output.code, 1, "stderr: {}", output.stderr);
    assert_eq!(output.stdout, "", "a home-root search leaked: {}", output.stdout);
    for root in EXEC_INTERNAL_ROOTS {
        assert!(
            !output.stderr.contains(root),
            "the walk must not name {root}: {}",
            output.stderr
        );
    }
}

#[test]
fn capabilities_json_is_not_internal_state() {
    let fixture = fixture("policy-allowed");
    let output = run(
        &fixture,
        "/dsh/workspace",
        &["-n", "capabilities", "/dsh/home/capabilities.json"],
    );
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert!(
        output.stdout.contains("{\"capabilities\":true}"),
        "stdout: {}",
        output.stdout
    );
    assert_eq!(output.stderr, "");
}

#[test]
fn a_relative_operand_and_dot_segments_are_refused_too() {
    let fixture = fixture("policy-relative");
    let relative = run(&fixture, "/dsh/home", &["-n", "secret", "sessions"]);
    assert_eq!(relative.code, 2, "stderr: {}", relative.stderr);
    assert_eq!(relative.stdout, "");
    assert!(
        relative
            .stderr
            .contains(&expected("/dsh/home/sessions", "/dsh/home/sessions")),
        "stderr: {}",
        relative.stderr
    );

    let dotted = run(
        &fixture,
        "/dsh/workspace",
        &["-n", "secret", "/dsh/home/notes/../sessions"],
    );
    assert_eq!(dotted.code, 2, "stderr: {}", dotted.stderr);
    assert_eq!(dotted.stdout, "");
    assert!(
        dotted
            .stderr
            .contains(&expected("/dsh/home/sessions", "/dsh/home/sessions")),
        "stderr: {}",
        dotted.stderr
    );
}
