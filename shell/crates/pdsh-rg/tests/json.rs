// SPDX-License-Identifier: MIT
//! `rg --json`: the line format DSH's `grep.ts` parses.
//!
//! The expected objects below are hand-written from ripgrep's documented JSON
//! format (`begin`, `match`, `context`, `end`, `summary`); timing fields are
//! checked for shape, never for a value.

mod common;

use common::{contexts, ends, json_line, json_lines, matches, run, summary, Fixture};
use serde_json::json;

#[test]
fn begin_and_match_records_have_exact_fields() {
    let fixture = Fixture::new("json-match");
    fixture.write("a.txt", "foo bar\nbaz foo\n");
    let output = run(&fixture, "/dsh/workspace", &["--json", "--regexp=foo"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    let records = json_lines(&output);
    assert_eq!(records.len(), 5, "begin, match, match, end, summary");

    assert_eq!(
        records[0],
        json!({
            "type": "begin",
            "data": { "path": { "text": "a.txt" } }
        })
    );
    assert_eq!(
        records[1],
        json!({
            "type": "match",
            "data": {
                "path": { "text": "a.txt" },
                "lines": { "text": "foo bar\n" },
                "line_number": 1,
                "absolute_offset": 0,
                "submatches": [
                    { "match": { "text": "foo" }, "start": 0, "end": 3 }
                ]
            }
        })
    );
    assert_eq!(
        records[2],
        json!({
            "type": "match",
            "data": {
                "path": { "text": "a.txt" },
                "lines": { "text": "baz foo\n" },
                "line_number": 2,
                "absolute_offset": 8,
                "submatches": [
                    { "match": { "text": "foo" }, "start": 4, "end": 7 }
                ]
            }
        })
    );
    assert_eq!(records[3]["type"], "end");
    assert_eq!(records[3]["data"]["path"]["text"], "a.txt");
    assert_eq!(records[3]["data"]["binary_offset"], serde_json::Value::Null);
    assert_eq!(records[3]["data"]["stats"]["searches"], 1);
    assert_eq!(records[3]["data"]["stats"]["searches_with_match"], 1);
    assert_eq!(records[3]["data"]["stats"]["matches"], 2);
    assert_eq!(records[3]["data"]["stats"]["matched_lines"], 2);
    assert_eq!(records[3]["data"]["stats"]["bytes_searched"], 16);
    assert!(records[3]["data"]["stats"]["bytes_printed"].as_u64().unwrap() > 0);
    assert!(records[3]["data"]["stats"]["elapsed"]["nanos"].is_u64());
    assert_eq!(records[3]["data"]["stats"]["elapsed"]["secs"], 0);
    assert!(records[3]["data"]["stats"]["elapsed"]["human"]
        .as_str()
        .unwrap()
        .ends_with('s'));

    assert_eq!(records[4]["type"], "summary");
    assert_eq!(records[4]["data"]["stats"]["searches"], 1);
    assert_eq!(records[4]["data"]["stats"]["searches_with_match"], 1);
    assert_eq!(records[4]["data"]["stats"]["matches"], 2);
    assert_eq!(records[4]["data"]["stats"]["bytes_searched"], 16);
    assert!(records[4]["data"]["elapsed_total"]["nanos"].is_u64());
}

#[test]
fn every_match_on_a_line_reports_its_own_byte_offsets() {
    let fixture = Fixture::new("json-submatches");
    fixture.write("a.txt", "xx foo yy foo\n");
    let output = run(&fixture, "/dsh/workspace", &["--json", "-e", "foo"]);
    let matches = matches(&output);
    assert_eq!(matches.len(), 1);
    assert_eq!(
        matches[0]["data"]["submatches"],
        json!([
            { "match": { "text": "foo" }, "start": 3, "end": 6 },
            { "match": { "text": "foo" }, "start": 10, "end": 13 }
        ])
    );
    assert_eq!(matches[0]["data"]["absolute_offset"], 0);
}

#[test]
fn context_records_come_from_the_context_flags() {
    let fixture = Fixture::new("json-context");
    fixture.write("a.txt", "one\ntwo\nneedle\nfour\nfive\n");
    let output = run(
        &fixture,
        "/dsh/workspace",
        &["--json", "-C", "1", "-e", "needle"],
    );
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    let records = json_lines(&output);
    let types: Vec<&str> = records
        .iter()
        .map(|record| record["type"].as_str().unwrap())
        .collect();
    assert_eq!(
        types,
        vec!["begin", "context", "match", "context", "end", "summary"]
    );
    let contexts = contexts(&output);
    assert_eq!(contexts.len(), 2);
    assert_eq!(
        contexts[0],
        json!({
            "type": "context",
            "data": {
                "path": { "text": "a.txt" },
                "lines": { "text": "two\n" },
                "line_number": 2,
                "absolute_offset": 4,
                "submatches": []
            }
        })
    );
    assert_eq!(contexts[1]["data"]["lines"]["text"], "four\n");
    assert_eq!(contexts[1]["data"]["line_number"], 4);
}

#[test]
fn files_without_matches_produce_no_begin_or_end_records() {
    let fixture = Fixture::new("json-nomatch-file");
    fixture.write("a.txt", "nothing here\n");
    fixture.write("b.txt", "a needle\n");
    let output = run(&fixture, "/dsh/workspace", &["--json", "-e", "needle"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    let begins = common::begins(&output);
    let ends = ends(&output);
    assert_eq!(begins.len(), 1);
    assert_eq!(begins[0]["data"]["path"]["text"], "b.txt");
    assert_eq!(ends.len(), 1);
    assert_eq!(ends[0]["data"]["path"]["text"], "b.txt");
    let summary = summary(&output);
    assert_eq!(summary["data"]["stats"]["searches"], 2);
    assert_eq!(summary["data"]["stats"]["searches_with_match"], 1);
}

#[test]
fn a_binary_file_is_not_reported_as_text_matches() {
    let fixture = Fixture::new("json-binary");
    fixture.write_bytes("bin.dat", b"needle\x00more\n");
    fixture.write("text.txt", "needle\n");
    let output = run(&fixture, "/dsh/workspace", &["--json", "-e", "needle"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    for record in matches(&output) {
        assert_eq!(record["data"]["path"]["text"], "text.txt");
    }
    let summary = summary(&output);
    assert_eq!(summary["data"]["stats"]["searches"], 2);
}

#[test]
fn a_non_utf8_line_uses_the_bytes_shape_grep_ts_handles() {
    // Ported from DSH's tool-fs-search tests (`tools.spec.ts`,
    // "renders a non-UTF-8 line (rg bytes form) as a placeholder"): the
    // printer must emit `lines.bytes`, never mangled `lines.text`.
    let fixture = Fixture::new("json-bytes");
    fixture.write_bytes("bin.dat", b"foo\xff\n");
    let output = run(&fixture, "/dsh/workspace", &["--json", "-e", "foo"]);
    let matches = matches(&output);
    assert_eq!(matches.len(), 1, "stderr: {}", output.stderr);
    assert_eq!(matches[0]["data"]["path"]["text"], "bin.dat");
    assert!(matches[0]["data"]["lines"]["text"].is_null());
    assert!(matches[0]["data"]["lines"]["bytes"].is_string());
    assert_eq!(matches[0]["data"]["line_number"], 1);
}

#[test]
fn a_crlf_line_keeps_its_carriage_return_for_the_parser_to_strip() {
    // Ported from DSH's tool-fs-search tests (`tools.spec.ts`, "strips a CRLF
    // terminator from the matched line text"): `lines.text` carries the CRLF
    // and `grep.ts` strips it; the accelerator must not pre-strip it.
    let fixture = Fixture::new("json-crlf");
    fixture.write_bytes("a.txt", b"windows line\r\n");
    let output = run(&fixture, "/dsh/workspace", &["--json", "-e", "windows"]);
    let matches = matches(&output);
    assert_eq!(matches.len(), 1);
    assert_eq!(
        matches[0]["data"]["lines"]["text"],
        "windows line\r\n"
    );
}

#[test]
fn match_records_are_valid_json_lines_with_no_pretty_printing() {
    let fixture = Fixture::new("json-lines");
    fixture.write("a.txt", "foo\n");
    let output = run(&fixture, "/dsh/workspace", &["--json", "-e", "foo"]);
    for line in output.lines() {
        assert!(!line.contains("\n"));
        assert!(line.starts_with('{'));
        let value = json_line(line);
        assert!(value["type"].is_string());
        assert!(value["data"].is_object());
    }
    assert!(output.stdout.ends_with('\n'));
}

#[test]
fn the_summary_is_emitted_even_with_zero_matches() {
    let fixture = Fixture::new("json-summary-empty");
    fixture.write("a.txt", "nothing\n");
    let output = run(&fixture, "/dsh/workspace", &["--json", "-e", "needle"]);
    assert_eq!(output.code, 1, "stderr: {}", output.stderr);
    assert!(matches(&output).is_empty());
    let summary = summary(&output);
    assert_eq!(summary["data"]["stats"]["matches"], 0);
    assert_eq!(summary["data"]["stats"]["searches"], 1);
    assert_eq!(summary["data"]["stats"]["searches_with_match"], 0);
}

#[test]
fn max_count_limits_matches_per_file_not_globally() {
    let fixture = Fixture::new("json-max-count");
    fixture.write("a.txt", "foo\nfoo\nfoo\n");
    fixture.write("b.txt", "foo\nfoo\n");
    let output = run(
        &fixture,
        "/dsh/workspace",
        &["--json", "-m", "2", "-e", "foo", "--sort=path"],
    );
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    let matches = matches(&output);
    assert_eq!(matches.len(), 4);
    assert_eq!(matches.iter().filter(|m| m["data"]["path"]["text"] == "a.txt").count(), 2);
    assert_eq!(matches.iter().filter(|m| m["data"]["path"]["text"] == "b.txt").count(), 2);
}

#[test]
fn multiple_regexp_patterns_are_alternatives() {
    let fixture = Fixture::new("json-multi-pattern");
    fixture.write("a.txt", "alpha\nbeta\ngamma\n");
    let output = run(
        &fixture,
        "/dsh/workspace",
        &["--json", "-e", "alpha", "-e", "gamma"],
    );
    let matches = matches(&output);
    assert_eq!(matches.len(), 2);
    assert_eq!(matches[0]["data"]["lines"]["text"], "alpha\n");
    assert_eq!(matches[1]["data"]["lines"]["text"], "gamma\n");
}
