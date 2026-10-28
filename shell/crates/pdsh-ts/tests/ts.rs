// SPDX-License-Identifier: MIT
//! `ts-parse` / `ts-query` tests across the bundled grammars.

mod common;

use common::{run, run_with, Fixture};
use serde_json::Value;
use pdsh_core::{CancelToken, Limits};

#[test]
fn typescript_parses_to_an_sexp() {
    let fixture = Fixture::new("ts-parse-typescript");
    fixture.write("a.ts", "const x: number = 1;\n");
    let output = run(&fixture, "ts-parse", &["a.ts"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert!(output.stdout.starts_with("(program "));
    assert!(output.stdout.contains("lexical_declaration"));
    assert!(output.stdout.contains("identifier"));
    assert!(output.stdout.ends_with(")\n"));
}

#[test]
fn tsx_uses_the_tsx_grammar() {
    let fixture = Fixture::new("ts-parse-tsx");
    fixture.write("a.tsx", "const el = <div>hi</div>;\n");
    let output = run(&fixture, "ts-parse", &["a.tsx"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert!(output.stdout.contains("jsx_element"));
}

#[test]
fn javascript_parses_a_function() {
    let fixture = Fixture::new("ts-parse-javascript");
    fixture.write("a.js", "function f() { return 1; }\n");
    let output = run(&fixture, "ts-parse", &["a.js"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert!(output.stdout.starts_with("(program "));
    assert!(output.stdout.contains("function_declaration"));
}

#[test]
fn swift_parses_a_property() {
    let fixture = Fixture::new("ts-parse-swift");
    fixture.write("a.swift", "let x = 1\n");
    let output = run(&fixture, "ts-parse", &["a.swift"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert!(output.stdout.starts_with("(source_file "));
    assert!(output.stdout.contains("property_declaration"));
}

#[test]
fn python_parses_a_function_definition() {
    let fixture = Fixture::new("ts-parse-python");
    fixture.write("a.py", "def f(x):\n    return x\n");
    let output = run(&fixture, "ts-parse", &["a.py"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert!(output.stdout.starts_with("(module "));
    assert!(output.stdout.contains("function_definition"));
}

#[test]
fn rust_parses_a_function_item() {
    let fixture = Fixture::new("ts-parse-rust");
    fixture.write("a.rs", "fn main() { let x = 1; }\n");
    let output = run(&fixture, "ts-parse", &["a.rs"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert!(output.stdout.starts_with("(source_file "));
    assert!(output.stdout.contains("function_item"));
    assert!(output.stdout.contains("let_declaration"));
}

#[test]
fn c_parses_a_translation_unit() {
    let fixture = Fixture::new("ts-parse-c");
    fixture.write("a.c", "int main(void) { return 0; }\n");
    let output = run(&fixture, "ts-parse", &["a.c"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert!(output.stdout.starts_with("(translation_unit "));
    assert!(output.stdout.contains("function_definition"));
}

#[test]
fn json_parses_a_document() {
    let fixture = Fixture::new("ts-parse-json");
    fixture.write("a.json", "{\"a\": 1}\n");
    let output = run(&fixture, "ts-parse", &["a.json"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert!(output.stdout.starts_with("(document "));
    assert!(output.stdout.contains("object"));
    assert!(output.stdout.contains("pair"));
}

#[test]
fn json_output_has_type_offsets_and_children() {
    let fixture = Fixture::new("ts-parse-json-output");
    let source = "fn main() {}\n";
    fixture.write("a.rs", source);
    let output = run(&fixture, "ts-parse", &["--json", "a.rs"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    let value: Value = serde_json::from_str(output.stdout.trim()).unwrap();
    assert_eq!(value["type"], "source_file");
    assert_eq!(value["start"], 0);
    assert_eq!(value["end"], source.len());
    let child = &value["children"][0];
    assert_eq!(child["type"], "function_item");
    assert_eq!(child["start"], 0);
    assert_eq!(child["end"], source.trim_end().len());
    assert!(child["children"].is_array());

    // Field names are recorded where the grammar labels a child, e.g. the
    // `name` field of a function item.
    fn find_field<'a>(value: &'a Value, field: &str) -> Option<&'a Value> {
        if value["field"] == field {
            return Some(value);
        }
        for child in value["children"].as_array()? {
            if let Some(found) = find_field(child, field) {
                return Some(found);
            }
        }
        None
    }
    let name = find_field(&value, "name").expect("a name field");
    assert_eq!(name["type"], "identifier");
    assert_eq!(name["start"], 3);
    assert_eq!(name["end"], 7);
}

#[test]
fn max_depth_omits_deeper_children() {
    let fixture = Fixture::new("ts-parse-depth");
    fixture.write("a.rs", "fn main() { let x = 1; }\n");
    let output = run(&fixture, "ts-parse", &["--max-depth", "0", "a.rs"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(output.stdout, "(source_file)\n");
    let output = run(&fixture, "ts-parse", &["--max-depth", "1", "a.rs"]);
    assert!(output.stdout.contains("function_item"));
    assert!(!output.stdout.contains("block"), "stdout: {}", output.stdout);
}

#[test]
fn an_unknown_extension_requires_lang() {
    let fixture = Fixture::new("ts-parse-lang");
    fixture.write("a.txt", "fn main() {}\n");
    let output = run(&fixture, "ts-parse", &["a.txt"]);
    assert_eq!(output.code, 2);
    assert!(output.stderr.contains("--lang"));
    let output = run(&fixture, "ts-parse", &["--lang", "rust", "a.txt"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert!(output.stdout.contains("function_item"));
    let output = run(&fixture, "ts-parse", &["--lang", "cobol", "a.txt"]);
    assert_eq!(output.code, 2);
    assert!(output.stderr.contains("unknown language"));
}

#[test]
fn a_missing_source_file_exits_2() {
    let fixture = Fixture::new("ts-parse-missing");
    let output = run(&fixture, "ts-parse", &["nope.rs"]);
    assert_eq!(output.code, 2);
    assert!(output.stderr.contains("nope.rs"));
}

#[test]
fn cancellation_returns_130() {
    let fixture = Fixture::new("ts-cancel");
    fixture.write("a.rs", "fn main() {}\n");
    let token = CancelToken::new();
    token.cancel();
    let output = run_with(
        &fixture,
        "ts-parse",
        &["a.rs"],
        Limits::default(),
        Some(token),
    );
    assert_eq!(output.code, 130);
}

#[test]
fn rust_query_captures_identifiers() {
    let fixture = Fixture::new("ts-query-rust");
    fixture.write("a.rs", "fn main() { let x = 1; }\n");
    let output = run(&fixture, "ts-query", &["a.rs", "(identifier) @id"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    let rows: Vec<Value> = output
        .stdout
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    // One capture row per captured node.
    assert_eq!(rows.len(), 2);
    let names: Vec<&str> = rows
        .iter()
        .map(|row| row["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, vec!["id", "id"]);
    let texts: Vec<&str> = rows
        .iter()
        .map(|row| row["text"].as_str().unwrap())
        .collect();
    assert_eq!(texts, vec!["main", "x"]);
}

#[test]
fn captures_is_the_default_output_shape() {
    let fixture = Fixture::new("ts-query-captures-default");
    fixture.write("a.rs", "fn main() { let value = 1; }\n");
    let plain = run(&fixture, "ts-query", &["a.rs", "(identifier) @id"]);
    let flagged = run(
        &fixture,
        "ts-query",
        &["a.rs", "(identifier) @id", "--captures"],
    );
    assert_eq!(plain.code, 0, "stderr: {}", plain.stderr);
    assert_eq!(plain.stdout, flagged.stdout);
    for line in plain.stdout.lines() {
        let row: Value = serde_json::from_str(line).unwrap();
        assert!(row.get("name").is_some());
        assert!(row.get("start").is_some());
        assert!(row.get("end").is_some());
        assert!(row.get("text").is_some());
    }
}

#[test]
fn captures_flag_emits_flat_capture_rows() {
    let fixture = Fixture::new("ts-query-captures");
    let source = "fn main() {}\n";
    fixture.write("a.rs", source);
    let output = run(
        &fixture,
        "ts-query",
        &["a.rs", "(identifier) @id", "--captures"],
    );
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    let rows: Vec<Value> = output
        .stdout
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(rows.len(), 1);
    assert_eq!(
        rows[0],
        serde_json::json!({
            "name": "id",
            "start": 3,
            "end": 7,
            "text": "main"
        })
    );
}

#[test]
fn a_query_file_is_read_through_the_vfs() {
    let fixture = Fixture::new("ts-query-file");
    fixture.write("a.rs", "fn main() {}\n");
    fixture.write("query.scm", "(function_item name: (identifier) @name)\n");
    let output = run(
        &fixture,
        "ts-query",
        &["--captures", "a.rs", "query.scm"],
    );
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    let row: Value = serde_json::from_str(output.stdout.trim()).unwrap();
    assert_eq!(row["name"], "name");
    assert_eq!(row["text"], "main");
}

#[test]
fn typescript_and_python_queries_work() {
    let fixture = Fixture::new("ts-query-other");
    fixture.write("a.ts", "const answer: number = 42;\n");
    let output = run(
        &fixture,
        "ts-query",
        &[
            "--captures",
            "a.ts",
            "(variable_declarator name: (identifier) @name)",
        ],
    );
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    let row: Value = serde_json::from_str(output.stdout.trim()).unwrap();
    assert_eq!(row["text"], "answer");

    fixture.write("b.py", "def double(x):\n    return x * 2\n");
    let output = run(
        &fixture,
        "ts-query",
        &[
            "--captures",
            "b.py",
            "(function_definition name: (identifier) @fn)",
        ],
    );
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    let row: Value = serde_json::from_str(output.stdout.trim()).unwrap();
    assert_eq!(row["text"], "double");
}

#[test]
fn an_invalid_query_is_a_usage_error() {
    let fixture = Fixture::new("ts-query-invalid");
    fixture.write("a.rs", "fn main() {}\n");
    let output = run(
        &fixture,
        "ts-query",
        &["a.rs", "(this_node_does_not_exist) @x"],
    );
    assert_eq!(output.code, 2);
    assert!(output.stderr.contains("invalid query"));
}

#[test]
fn a_query_without_a_match_emits_nothing_and_succeeds() {
    let fixture = Fixture::new("ts-query-empty");
    fixture.write("a.rs", "fn main() {}\n");
    let output = run(&fixture, "ts-query", &["a.rs", "(string_literal) @s"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert!(output.stdout.is_empty());
}

#[test]
fn byte_offsets_index_the_vfs_source() {
    let fixture = Fixture::new("ts-query-offsets");
    let source = "fn alpha() { let beta = 2; }\n";
    fixture.write("a.rs", source);
    let output = run(
        &fixture,
        "ts-query",
        &["--captures", "a.rs", "(identifier) @id"],
    );
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    for line in output.stdout.lines() {
        let row: Value = serde_json::from_str(line).unwrap();
        let start = row["start"].as_u64().unwrap() as usize;
        let end = row["end"].as_u64().unwrap() as usize;
        assert_eq!(&source[start..end], row["text"].as_str().unwrap());
    }
}

#[test]
fn query_cancellation_returns_130() {
    let fixture = Fixture::new("ts-query-cancel");
    fixture.write("a.rs", "fn main() {}\n");
    let token = CancelToken::new();
    token.cancel();
    let output = run_with(
        &fixture,
        "ts-query",
        &["a.rs", "(identifier) @id"],
        Limits::default(),
        Some(token),
    );
    assert_eq!(output.code, 130);
}
