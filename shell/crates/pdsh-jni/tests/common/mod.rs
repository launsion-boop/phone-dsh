// SPDX-License-Identifier: MIT
//! Test-only helpers: the golden WAL vectors, a lowercase hex codec and a JSON
//! reader for the bridge's output.
//!
//! The vectors are read from `spec/v1/golden/wal/`; the crate under test does
//! no I/O, so a test is the only place a file is opened.

#![allow(dead_code)]

use std::fs;
use std::path::PathBuf;

use pdsh_wal::json::{self, Json};

/// The directory of the WAL conformance vectors.
pub fn golden_wal_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../spec/v1/golden/wal")
}

/// The raw bytes of one golden vector's `file_hex`.
pub fn golden_file(name: &str) -> Vec<u8> {
    let path = golden_wal_dir().join(name);
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
    let vector = json::parse(&text)
        .unwrap_or_else(|error| panic!("{} is not JSON: {error}", path.display()));
    hex_decode(
        vector
            .get("file_hex")
            .and_then(Json::as_str)
            .unwrap_or_else(|| panic!("{} has no file_hex member", path.display())),
    )
}

/// One golden vector's parsed JSON document.
pub fn golden_vector(name: &str) -> Json {
    let path = golden_wal_dir().join(name);
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
    json::parse(&text).unwrap_or_else(|error| panic!("{} is not JSON: {error}", path.display()))
}

/// The `record_hex` bytes of every record of one golden vector, in file order.
pub fn golden_records(name: &str) -> Vec<Vec<u8>> {
    let vector = golden_vector(name);
    vector
        .get("records")
        .and_then(Json::as_array)
        .unwrap_or_else(|| panic!("{name} has no records array"))
        .iter()
        .map(|record| {
            hex_decode(
                record
                    .get("record_hex")
                    .and_then(Json::as_str)
                    .unwrap_or_else(|| panic!("{name}: a record has no record_hex")),
            )
        })
        .collect()
}

/// The `header_hex` bytes of one golden vector.
pub fn golden_header(name: &str) -> Vec<u8> {
    let vector = golden_vector(name);
    hex_decode(
        vector
            .get("header")
            .and_then(|header| header.get("header_hex"))
            .and_then(Json::as_str)
            .unwrap_or_else(|| panic!("{name} has no header.header_hex")),
    )
}

/// Parses one of the bridge's JSON outputs.
pub fn parse_json(text: &str) -> Json {
    json::parse(text).unwrap_or_else(|error| panic!("bridge output is not JSON: {error}\n{text}"))
}

/// The string member `name`, panicking when absent or not a string.
pub fn string_member<'a>(json: &'a Json, name: &str) -> &'a str {
    json.get(name)
        .and_then(Json::as_str)
        .unwrap_or_else(|| panic!("member {name:?} is not a string in {json:?}"))
}

/// Bytes of a lowercase hex string.
pub fn hex_decode(text: &str) -> Vec<u8> {
    assert!(text.len() % 2 == 0, "hex text has an odd length");
    (0..text.len())
        .step_by(2)
        .map(|index| {
            u8::from_str_radix(&text[index..index + 2], 16).expect("hex pair is lowercase hex")
        })
        .collect()
}

/// Lowercase hex of `bytes`.
pub fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}
