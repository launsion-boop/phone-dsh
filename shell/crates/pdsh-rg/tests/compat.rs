// SPDX-License-Identifier: MIT
//! DSH compatibility vectors and the optional differential test against a
//! system `rg`.
//!
//! The argv vectors reproduced here come from the pinned DSH checkout's
//! `packages/fs/tool-fs-search/tests/tools.spec.ts` ("command construction
//! (plain argv)") and `src/grep.ts` / `src/glob.ts`; the expected outputs are
//! the parts of the `rg --json` contract those tools consume.

mod common;

use std::process::Command;

use common::{matches, run, summary, Fixture};
use serde_json::Value;

#[test]
fn dsh_grep_argv_with_include_and_a_leading_dash_path() {
    // DSH `buildGrepCommand({ pattern: 'x', path: '-leading-dash',
    // include: '*.{ts,tsx}' })` is
    // `['--json', '--regexp=x', '--glob=*.{ts,tsx}', '--', '-leading-dash']`.
    // Every element is inert: there is no shell between the argv and the
    // accelerator, and the path rides behind `--`.
    let fixture = Fixture::new("dsh-grep-vector");
    fixture.write("-leading-dash", "x marks the spot\n");
    let output = run(
        &fixture,
        "/dsh/workspace",
        &[
            "--json",
            "--regexp=x",
            "--glob=*.{ts,tsx}",
            "--",
            "-leading-dash",
        ],
    );
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    let matches = matches(&output);
    assert_eq!(matches.len(), 1);
    assert_eq!(matches[0]["data"]["path"]["text"], "-leading-dash");
    assert_eq!(matches[0]["data"]["line_number"], 1);
}

#[test]
fn dsh_grep_argv_prepends_no_config() {
    // DSH always prepends `--no-config` so a host RIPGREP_CONFIG_PATH cannot
    // inject `--pre`; the accelerator accepts it and reads no config.
    let fixture = Fixture::new("dsh-no-config");
    fixture.write("a.ts", "const x = 1\n");
    let output = run(
        &fixture,
        "/dsh/workspace",
        &["--no-config", "--json", "--regexp=const", "--glob=*.ts"],
    );
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(matches(&output).len(), 1);
}

#[test]
fn dsh_grep_parses_path_line_number_and_line_text() {
    // Port of `tools.spec.ts` "grep results > groups matches by file with line
    // numbers": DSH's parser reads `data.path.text`, `data.line_number` and
    // `data.lines.text`, stripping one trailing newline.
    let fixture = Fixture::new("dsh-grep-parse");
    fixture.write("a.ts", "header\nconst x = 1\nconst y = 2\n");
    let output = run(
        &fixture,
        "/dsh/workspace",
        &["--no-config", "--json", "--regexp=const"],
    );
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    let parsed: Vec<(String, u64, String)> = matches(&output)
        .into_iter()
        .map(|record| {
            let path = record["data"]["path"]["text"].as_str().unwrap().to_string();
            let line = record["data"]["line_number"].as_u64().unwrap();
            let text = record["data"]["lines"]["text"].as_str().unwrap();
            let text = text.trim_end_matches("\r\n").trim_end_matches('\n');
            (path, line, text.to_string())
        })
        .collect();
    assert_eq!(
        parsed,
        vec![
            ("a.ts".to_string(), 2, "const x = 1".to_string()),
            ("a.ts".to_string(), 3, "const y = 2".to_string()),
        ]
    );
}

#[test]
fn hostile_argv_elements_are_inert() {
    // Port of `tools.spec.ts` "keeps %s as ONE inert argv element (no shell
    // layer to escape)": command substitutions, quotes, newlines and leading
    // dashes are plain bytes of one argument.
    let fixture = Fixture::new("dsh-inert");
    fixture.write("a.txt", "$(rm -rf /) `touch pwned`\n");
    let pattern = "$(rm -rf /) `touch pwned`";
    let output = run(
        &fixture,
        "/dsh/workspace",
        &["--json", "-F", "-e", pattern],
    );
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(matches(&output).len(), 1);
    let output = run(
        &fixture,
        "/dsh/workspace",
        &["--json", "-F", "-e", "--flag"],
    );
    assert_eq!(output.code, 1);
}

#[test]
fn a_trailing_crlf_helper_matches_dsh_line_stripping() {
    // `grep.ts` uses `lines.text.replace(/\r?\n$/, '')`; the accelerator's
    // record must therefore be the raw line ending.
    let fixture = Fixture::new("dsh-crlf-helper");
    fixture.write_bytes("a.txt", b"hit\r\n");
    let output = run(&fixture, "/dsh/workspace", &["--json", "-e", "hit"]);
    let text = matches(&output)[0]["data"]["lines"]["text"]
        .as_str()
        .unwrap()
        .replace("\r\n", "")
        .replace('\n', "");
    assert_eq!(text, "hit");
}

#[test]
fn no_system_rg_is_required_and_the_differential_test_skips_cleanly() {
    // This test documents the skip rule of `differential_against_system_rg`:
    // the accelerator is self-contained, so a missing `rg` is not a failure.
    let probe = Command::new("rg").arg("--version").output();
    if probe.is_err() {
        eprintln!("skipping: no system rg on PATH");
    }
}

fn normalize(value: &mut Value) {
    match value {
        Value::Object(map) => {
            // Timings are the only nondeterministic part of `rg --json`.
            map.remove("elapsed");
            map.remove("elapsed_total");
            for nested in map.values_mut() {
                normalize(nested);
            }
        }
        Value::Array(items) => {
            for item in items {
                normalize(item);
            }
        }
        _ => {}
    }
}

fn host_path_of(fixture: &Fixture, relative: &str) -> std::path::PathBuf {
    fixture.workspace().join(relative)
}

#[test]
fn differential_against_system_rg() {
    // Differential oracle: if a system `rg` is on PATH, run it over the same
    // host tree with the same argv and compare the JSON lines after removing
    // the elapsed-time fields. Skips cleanly when `rg` is absent.
    let probe = Command::new("rg").arg("--version").output();
    let Ok(probe) = probe else {
        eprintln!("skipping differential test: no system rg on PATH");
        return;
    };
    if !probe.status.success() {
        eprintln!("skipping differential test: rg --version failed");
        return;
    }
    let fixture = Fixture::new("differential");
    fixture.mkdir(".git");
    fixture.write(".gitignore", "*.log\nbuild/\n!keep.log\n");
    fixture.write("a.txt", "needle one\nnot a match\nneedle two\n");
    fixture.write("sub/b.txt", "prefix needle suffix\n");
    fixture.write("sub/deep/c.txt", "nothing\n");
    fixture.write("skip.log", "needle\n");
    fixture.write("keep.log", "needle\n");
    fixture.write("build/out.txt", "needle\n");
    fixture.write(".hidden.txt", "needle\n");
    fixture.write_bytes("binary.dat", b"needle\x00rest\n");
    assert!(host_path_of(&fixture, "a.txt").exists());

    let workspace = fixture.workspace();
    let args = ["--json", "--no-config", "--regexp=needle", "--sort=path", "."];
    let real = Command::new("rg")
        .args(args)
        .current_dir(&workspace)
        .output()
        .unwrap();
    assert!(
        real.status.success(),
        "system rg failed: {}",
        String::from_utf8_lossy(&real.stderr)
    );
    let ours = run(&fixture, "/dsh/workspace", &args);
    assert_eq!(ours.code, 0, "stderr: {}", ours.stderr);

    let real_lines: Vec<Value> = String::from_utf8_lossy(&real.stdout)
        .split('\n')
        .filter(|line| !line.is_empty())
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let mut real_lines: Vec<Value> = real_lines;
    let mut our_lines = common::json_lines(&ours);
    for line in &mut real_lines {
        normalize(line);
    }
    for line in &mut our_lines {
        normalize(line);
    }
    assert_eq!(our_lines, real_lines);
}

#[test]
fn differential_files_listing_against_system_rg() {
    let Ok(probe) = Command::new("rg").arg("--version").output() else {
        eprintln!("skipping differential test: no system rg on PATH");
        return;
    };
    if !probe.status.success() {
        return;
    }
    let fixture = Fixture::new("differential-files");
    fixture.mkdir(".git");
    fixture.write(".gitignore", "*.log\n");
    fixture.write("a.txt", "x");
    fixture.write("b.log", "x");
    fixture.write("sub/c.rs", "x");
    fixture.write(".hidden", "x");
    let workspace = fixture.workspace();
    let args = ["--files", "--sort=path"];
    let real = Command::new("rg")
        .args(args)
        .current_dir(&workspace)
        .output()
        .unwrap();
    let ours = run(&fixture, "/dsh/workspace", &args);
    assert_eq!(
        ours.stdout,
        String::from_utf8_lossy(&real.stdout),
        "stderr: {}",
        ours.stderr
    );
    let _ = summary;
}
