// SPDX-License-Identifier: MIT
//! `jaq` / `jq` compatibility tests.
//!
//! Input files live in a temporary `/dsh/workspace` mount and are always read
//! through the pdsh-core VFS; the expected outputs are jq's (and therefore jaq's)
//! canonical JSON text.

mod common;

use common::{run, run_input, Fixture};
use pdsh_core::Limits;

fn args(items: &[&str]) -> Vec<String> {
    items.iter().map(|item| (*item).to_string()).collect()
}

#[test]
fn identity_pretty_prints_with_two_spaces() {
    let fixture = Fixture::new("jaq-pretty");
    fixture.write("in.json", "{\"a\":1}\n");
    let output = run(&fixture, &args(&[".", "in.json"]));
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(output.stdout, "{\n  \"a\": 1\n}\n");
}

#[test]
fn nested_fields_are_selected_like_jq() {
    let fixture = Fixture::new("jaq-nested");
    fixture.write("in.json", "{\"a\":{\"b\":[1,2,3]}}\n");
    let output = run(&fixture, &args(&[".a.b", "in.json"]));
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(output.stdout, "[\n  1,\n  2,\n  3\n]\n");
}

#[test]
fn array_iteration_emits_one_value_per_line() {
    let fixture = Fixture::new("jaq-iterate");
    fixture.write("in.json", "[1,2,3]\n");
    let output = run(&fixture, &args(&[".[]", "in.json"]));
    assert_eq!(output.stdout, "1\n2\n3\n");
}

#[test]
fn select_and_map_follow_jq() {
    let fixture = Fixture::new("jaq-select");
    fixture.write("in.json", "[1,2,3,4]\n");
    let output = run(&fixture, &args(&["map(select(. > 2))", "in.json"]));
    assert_eq!(output.stdout, "[\n  3,\n  4\n]\n");
}

#[test]
fn keys_and_to_entries_are_available() {
    let fixture = Fixture::new("jaq-keys");
    fixture.write("in.json", "{\"b\":2,\"a\":1}\n");
    let output = run(&fixture, &args(&["keys", "in.json"]));
    assert_eq!(output.stdout, "[\n  \"a\",\n  \"b\"\n]\n");
    let output = run(&fixture, &args(&["to_entries", "in.json"]));
    assert!(output.stdout.contains("\"key\": \"a\""));
    assert!(output.stdout.contains("\"value\": 1"));
}

#[test]
fn base64_formatting_is_supported() {
    let fixture = Fixture::new("jaq-base64");
    fixture.write("in.json", "\"hello\"\n");
    let output = run(&fixture, &args(&["@base64", "in.json"]));
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(output.stdout, "\"aGVsbG8=\"\n");
}

#[test]
fn string_interpolation_is_supported() {
    let fixture = Fixture::new("jaq-interp");
    fixture.write("in.json", "{\"x\":\"world\"}\n");
    let output = run(&fixture, &args(&["\"hello \\(.x)\"", "in.json"]));
    assert_eq!(output.stdout, "\"hello world\"\n");
}

#[test]
fn raw_output_writes_strings_without_quotes() {
    let fixture = Fixture::new("jaq-raw");
    fixture.write("in.json", "\"line one\"\n");
    let output = run(&fixture, &args(&["-r", ".", "in.json"]));
    assert_eq!(output.stdout, "line one\n");
}

#[test]
fn compact_output_writes_one_value_per_line() {
    let fixture = Fixture::new("jaq-compact");
    fixture.write("in.json", "{\"a\":[1,2]}\n");
    let output = run(&fixture, &args(&["-c", ".", "in.json"]));
    assert_eq!(output.stdout, "{\"a\":[1,2]}\n");
}

#[test]
fn slurp_reads_every_document_into_one_array() {
    let fixture = Fixture::new("jaq-slurp");
    fixture.write("in.json", "1 2 3\n");
    let output = run(&fixture, &args(&["-s", ".", "in.json"]));
    assert_eq!(output.stdout, "[\n  1,\n  2,\n  3\n]\n");
}

#[test]
fn null_input_runs_the_filter_once_without_reading_files() {
    let fixture = Fixture::new("jaq-null");
    let output = run(&fixture, &args(&["-n", "[1,2,3] | add"]));
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(output.stdout, "6\n");
}

#[test]
fn exit_status_reports_false_null_and_no_output() {
    let fixture = Fixture::new("jaq-exit-status");
    fixture.write("in.json", "true\n");
    let output = run(&fixture, &args(&["-e", ".", "in.json"]));
    assert_eq!(output.code, 0);
    fixture.write("in.json", "false\n");
    let output = run(&fixture, &args(&["-e", ".", "in.json"]));
    assert_eq!(output.code, 1);
    // No file argument and an empty standard input: `-e` sees no output.
    let output = run_input(&fixture, &args(&["-e", "empty"]), b"");
    assert_eq!(output.code, 4);
}

#[test]
fn arg_binds_a_string_variable() {
    let fixture = Fixture::new("jaq-arg");
    fixture.write("in.json", "{}\n");
    let output = run(
        &fixture,
        &args(&["--arg", "name", "world", "$name", "in.json"]),
    );
    assert_eq!(output.stdout, "\"world\"\n");
}

#[test]
fn argjson_binds_a_parsed_json_variable() {
    let fixture = Fixture::new("jaq-argjson");
    fixture.write("in.json", "40\n");
    let output = run(
        &fixture,
        &args(&["--argjson", "n", "2", ". + $n", "in.json"]),
    );
    assert_eq!(output.stdout, "42\n");
}

#[test]
fn an_invalid_argjson_value_is_a_runtime_error() {
    let fixture = Fixture::new("jaq-argjson-bad");
    fixture.write("in.json", "1\n");
    let output = run(
        &fixture,
        &args(&["--argjson", "n", "{", ".", "in.json"]),
    );
    assert_eq!(output.code, 5);
    assert!(output.stderr.contains("--argjson"));
}

#[test]
fn tab_and_explicit_indentation_change_the_layout() {
    let fixture = Fixture::new("jaq-indent");
    fixture.write("in.json", "{\"a\":{\"b\":1}}\n");
    let output = run(&fixture, &args(&["--tab", ".", "in.json"]));
    assert!(output.stdout.contains("\n\t\"a\""));
    let output = run(&fixture, &args(&["--indent", "4", ".", "in.json"]));
    assert!(output.stdout.contains("\n    \"a\""));
    let output = run(&fixture, &args(&["--indent", "0", ".", "in.json"]));
    assert!(output.stdout.contains("\n\"a\""));
}

#[test]
fn a_compile_error_exits_3() {
    let fixture = Fixture::new("jaq-compile");
    fixture.write("in.json", "{}\n");
    let output = run(&fixture, &args(&[".a |", "in.json"]));
    assert_eq!(output.code, 3);
    assert!(!output.stderr.is_empty());
}

#[test]
fn a_runtime_error_exits_5() {
    let fixture = Fixture::new("jaq-runtime");
    fixture.write("in.json", "1\n");
    let output = run(&fixture, &args(&["error(\"boom\")", "in.json"]));
    assert_eq!(output.code, 5);
    assert!(output.stderr.contains("boom"), "stderr: {}", output.stderr);
}

#[test]
fn a_missing_input_file_exits_5() {
    let fixture = Fixture::new("jaq-missing");
    let output = run(&fixture, &args(&[".", "missing.json"]));
    assert_eq!(output.code, 5);
    assert!(output.stderr.contains("missing.json"));
}

#[test]
fn multiple_files_are_processed_in_order() {
    let fixture = Fixture::new("jaq-multiple");
    fixture.write("one.json", "1\n");
    fixture.write("two.json", "2\n");
    let output = run(&fixture, &args(&[".", "one.json", "two.json"]));
    assert_eq!(output.stdout, "1\n2\n");
}

#[test]
fn stdin_is_supported_when_no_file_is_given() {
    let fixture = Fixture::new("jaq-stdin");
    let output = run_input(&fixture, &args(&["."]), b"[1,2]\n");
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(output.stdout, "[\n  1,\n  2\n]\n");
}

#[test]
fn output_budget_is_enforced() {
    let fixture = Fixture::new("jaq-budget");
    fixture.write("in.json", "[1,2,3,4,5,6]\n");
    let limits = Limits {
        max_output_bytes: 8,
        ..Limits::default()
    };
    let output = common::run_with_limits(&fixture, &args(&[".[]", "in.json"]), limits);
    assert!(output.stdout_truncated);
    assert!(output.stdout.contains("truncated"));
}

#[test]
fn jq_arithmetic_and_boolean_filters_work() {
    let fixture = Fixture::new("jaq-arithmetic");
    fixture.write("in.json", "{\"n\":3}\n");
    let output = run(
        &fixture,
        &args(&[
            "[.n, .n + 1, .n * 2] | map(tostring) | join(\",\")",
            "in.json",
        ]),
    );
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(output.stdout, "\"3,4,6\"\n");
}

#[test]
fn undefined_variables_are_compile_errors() {
    let fixture = Fixture::new("jaq-undefined");
    fixture.write("in.json", "{}\n");
    let output = run(&fixture, &args(&["$nope", "in.json"]));
    assert_eq!(output.code, 3);
}

#[test]
fn a_pre_cancelled_token_returns_130() {
    let fixture = Fixture::new("jaq-cancel");
    fixture.write("in.json", "1\n");
    let token = pdsh_core::CancelToken::new();
    token.cancel();
    let output = common::run_with_cancel(&fixture, &args(&[".", "in.json"]), token);
    assert_eq!(output.code, 130);
    assert!(output.stdout.is_empty());
}

#[test]
fn the_pretty_printer_does_not_escape_slashes() {
    let fixture = Fixture::new("jaq-slashes");
    fixture.write("in.json", "\"a/b\"\n");
    let output = run(&fixture, &args(&[".", "in.json"]));
    assert_eq!(output.stdout, "\"a/b\"\n");
}
