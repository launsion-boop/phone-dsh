// SPDX-License-Identifier: MIT
//! Matching options, text output, cancellation and output budgets.

mod common;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use common::{run, run_with, Fixture};
use pdsh_core::{CancelToken, Limits};

#[test]
fn text_output_without_line_numbers_for_an_explicit_file() {
    let fixture = Fixture::new("text-file");
    fixture.write("a.txt", "xx foo\n");
    let output = run(&fixture, "/dsh/workspace", &["foo", "a.txt"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(output.stdout, "xx foo\n");
}

#[test]
fn text_output_prefixes_paths_when_searching_a_directory() {
    let fixture = Fixture::new("text-dir");
    fixture.write("a.txt", "xx foo\n");
    let output = run(&fixture, "/dsh/workspace", &["foo", "."]);
    assert_eq!(output.stdout, "./a.txt:xx foo\n");
}

#[test]
fn line_numbers_and_columns_match_ripgreps_order() {
    let fixture = Fixture::new("text-columns");
    fixture.write("a.txt", "xx foo\n");
    let output = run(&fixture, "/dsh/workspace", &["-n", "foo", "."]);
    assert_eq!(output.stdout, "./a.txt:1:xx foo\n");
    let output = run(&fixture, "/dsh/workspace", &["--column", "foo", "."]);
    // `--column` implies line numbers, exactly like ripgrep.
    assert_eq!(output.stdout, "./a.txt:1:4:xx foo\n");
    let output = run(&fixture, "/dsh/workspace", &["--column", "-n", "foo", "."]);
    assert_eq!(output.stdout, "./a.txt:1:4:xx foo\n");
}

#[test]
fn with_filename_forces_the_path_on_a_single_file() {
    let fixture = Fixture::new("text-H");
    fixture.write("a.txt", "foo\n");
    let output = run(&fixture, "/dsh/workspace", &["-H", "foo", "a.txt"]);
    assert_eq!(output.stdout, "a.txt:foo\n");
}

#[test]
fn fixed_strings_treat_regex_metacharacters_literally() {
    let fixture = Fixture::new("fixed");
    fixture.write("a.txt", "a.b\naxb\n");
    let output = run(&fixture, "/dsh/workspace", &["-F", "a.b"]);
    assert_eq!(output.code, 0);
    // The implicit root is the cwd directory, so the path is prefixed.
    assert_eq!(output.stdout, "a.txt:a.b\n");
}

#[test]
fn ignore_case_and_case_sensitive_override_each_other_in_order() {
    let fixture = Fixture::new("case");
    fixture.write("a.txt", "Needle\n");
    let output = run(&fixture, "/dsh/workspace", &["-i", "needle"]);
    assert_eq!(output.stdout, "a.txt:Needle\n");
    let output = run(&fixture, "/dsh/workspace", &["-i", "-s", "needle"]);
    assert_eq!(output.code, 1);
    let output = run(&fixture, "/dsh/workspace", &["-s", "-i", "needle"]);
    assert_eq!(output.code, 0);
}

#[test]
fn smart_case_is_insensitive_only_for_a_lowercase_pattern() {
    let fixture = Fixture::new("smart");
    fixture.write("a.txt", "Needle needle\n");
    let output = run(&fixture, "/dsh/workspace", &["-S", "needle"]);
    assert_eq!(output.code, 0);
    let output = run(&fixture, "/dsh/workspace", &["-S", "Needle"]);
    assert_eq!(output.code, 0);
    assert_eq!(output.stdout, "a.txt:Needle needle\n");
    let fixture = Fixture::new("smart-upper");
    fixture.write("a.txt", "NEEDLE\n");
    let output = run(&fixture, "/dsh/workspace", &["-S", "Needle"]);
    assert_eq!(output.code, 1);
}

#[test]
fn word_regexp_requires_word_boundaries() {
    let fixture = Fixture::new("word");
    fixture.write("a.txt", "foo foobar\n");
    let output = run(&fixture, "/dsh/workspace", &["-w", "foo"]);
    assert_eq!(output.code, 0);
    assert_eq!(output.stdout, "a.txt:foo foobar\n");
    let output = run(&fixture, "/dsh/workspace", &["-w", "--json", "foo"]);
    let matches = common::matches(&output);
    assert_eq!(matches.len(), 1);
    assert_eq!(matches[0]["data"]["submatches"][0]["start"], 0);
    assert_eq!(matches[0]["data"]["submatches"][0]["end"], 3);
}

#[test]
fn an_invalid_pattern_is_a_usage_error() {
    let fixture = Fixture::new("bad-pattern");
    fixture.write("a.txt", "x\n");
    let output = run(&fixture, "/dsh/workspace", &["("]);
    assert_eq!(output.code, 2);
    assert!(output.stderr.starts_with("rg: "), "stderr: {}", output.stderr);
}

#[test]
fn an_invalid_glob_is_a_usage_error() {
    let fixture = Fixture::new("bad-glob");
    fixture.write("a.txt", "x\n");
    let output = run(&fixture, "/dsh/workspace", &["--files", "--glob=[abc"]);
    assert_eq!(output.code, 2);
    assert!(output.stderr.contains("glob"), "stderr: {}", output.stderr);
}

#[test]
fn help_and_version_are_successful_and_do_not_search() {
    let fixture = Fixture::new("help");
    fixture.write("a.txt", "needle\n");
    let output = run(&fixture, "/dsh/workspace", &["--help"]);
    assert_eq!(output.code, 0);
    assert!(output.stdout.contains("USAGE"));
    let output = run(&fixture, "/dsh/workspace", &["--version"]);
    assert_eq!(output.code, 0);
    assert!(output.stdout.starts_with("rg "));
}

#[test]
fn a_pre_cancelled_token_returns_130_without_output() {
    let fixture = Fixture::new("cancel");
    fixture.write("a.txt", "needle\n");
    let token = CancelToken::new();
    token.cancel();
    let output = run_with(
        &fixture,
        "/dsh/workspace",
        &["--json", "needle"],
        Limits::default(),
        Some(token),
    );
    assert_eq!(output.code, 130);
    assert!(output.stdout.is_empty());
}

#[test]
fn cancellation_during_a_long_run_stops_it() {
    let fixture = Fixture::new("cancel-live");
    for index in 0..200 {
        fixture.write(&format!("dir{index:03}/file.txt"), "needle\n");
    }
    let token = CancelToken::new();
    let trigger = token.clone();
    let stopped = Arc::new(AtomicBool::new(false));
    let stop_flag = stopped.clone();
    let worker = thread::spawn(move || {
        let output = run_with(
            &fixture,
            "/dsh/workspace",
            &["needle"],
            Limits::default(),
            Some(token),
        );
        stop_flag.store(true, Ordering::SeqCst);
        output
    });
    for _ in 0..1000 {
        if stopped.load(Ordering::SeqCst) {
            break;
        }
        trigger.cancel();
        thread::sleep(Duration::from_millis(1));
    }
    let output = worker.join().unwrap();
    assert_eq!(output.code, 130, "stderr: {}", output.stderr);
}

#[test]
fn the_output_budget_truncates_with_the_core_marker() {
    let fixture = Fixture::new("budget");
    for index in 0..50 {
        fixture.write(&format!("f{index:02}.txt"), "needle\n");
    }
    let limits = Limits {
        max_output_bytes: 64,
        ..Limits::default()
    };
    let output = run_with(
        &fixture,
        "/dsh/workspace",
        &["--files"],
        limits,
        None,
    );
    assert_eq!(output.code, 0);
    assert!(output.stdout_truncated);
    assert!(output.stdout.contains("truncated"), "stdout: {}", output.stdout);
}

#[test]
fn json_and_files_are_mutually_exclusive_with_regexp() {
    let fixture = Fixture::new("files-regexp");
    fixture.write("a.txt", "x\n");
    let output = run(
        &fixture,
        "/dsh/workspace",
        &["--files", "-e", "x"],
    );
    assert_eq!(output.code, 2);
    assert!(output.stderr.contains("--files"));
}

#[test]
fn context_lines_are_printed_in_text_mode() {
    let fixture = Fixture::new("text-context");
    fixture.write("a.txt", "one\ntwo\nneedle\nfour\n");
    let output = run(&fixture, "/dsh/workspace", &["-C", "1", "needle", "a.txt"]);
    assert_eq!(output.code, 0);
    assert!(output.stdout.contains("two\n"));
    assert!(output.stdout.contains("four\n"));
    assert!(output.stdout.contains("needle\n"));
}
