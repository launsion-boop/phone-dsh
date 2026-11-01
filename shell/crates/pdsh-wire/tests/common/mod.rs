// SPDX-License-Identifier: MIT
//! Shared helpers for the golden-vector conformance tests.
//!
//! The 33 vectors are the 32 files of `spec/v1/golden/frames` plus the inline
//! `channel.md` §4.8 golden frame (identical bytes to `error-2.json`), which is
//! checked against the document text by the golden test. The file list is
//! fixed, so a removed or added vector fails the suite instead of passing
//! silently.

#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};

use pdsh_wire::{
    AckLevel, ApiAbort, ApiEnd, ApiRequest, ApiResponse, Frame, FrameType, Journal, JournalAck,
    JsonObject, JsonValue, VfsAck, VfsBarrier, VfsMutation, VfsOp, VfsResync,
};
use serde_json::Value as Json;

/// Every golden frame file, sorted; a missing or extra file fails the suite.
pub const EXPECTED_GOLDEN_FILES: [&str; 32] = [
    "api-abort-1.json",
    "api-end-1.json",
    "api-req-1.json",
    "api-res-1.json",
    "api-res-continuation-1.json",
    "api-res-empty-body-1.json",
    "console-1.json",
    "console-2.json",
    "error-1.json",
    "error-2.json",
    "error-3.json",
    "exec-ctl-1.json",
    "exec-ctl-2.json",
    "exec-evt-1.json",
    "exec-evt-2.json",
    "exec-req-1.json",
    "fence-1.json",
    "hello-host-1.json",
    "hello-worker-1.json",
    "journal-1.json",
    "journal-ack-1.json",
    "lifecycle-1.json",
    "vfs-ack-1.json",
    "vfs-ack-2.json",
    "vfs-barrier-1.json",
    "vfs-mut-append-1.json",
    "vfs-mut-binary-1.json",
    "vfs-mut-chmod-1.json",
    "vfs-mut-mkdir-1.json",
    "vfs-mut-remove-1.json",
    "vfs-mut-write-1.json",
    "vfs-resync-1.json",
];

/// The fixed number of golden frame vectors: 32 files plus the inline one.
pub const EXPECTED_GOLDEN_VECTORS: usize = 33;

/// The `spec/v1` directory, resolved from the crate manifest at compile time.
pub fn spec_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../spec/v1")
}

/// One golden frame vector.
pub struct GoldenVector {
    /// File name of the vector.
    pub name: String,
    /// The `type` member (normative name from `channel.md` §2).
    pub type_name: String,
    /// The `type_byte` member.
    pub type_byte: u8,
    /// The `seq` the header carries.
    pub seq: u64,
    /// The semantic payload.
    pub fields: Json,
    /// `payload_hex` as text.
    pub payload_hex: String,
    /// `payload_hex` as bytes.
    pub payload: Vec<u8>,
    /// `frame_hex` as text.
    pub frame_hex: String,
    /// `frame_hex` as bytes.
    pub frame: Vec<u8>,
}

/// Loads every golden frame vector, asserting the fixed file set and count.
pub fn load_golden_vectors() -> Vec<GoldenVector> {
    let directory = spec_root().join("golden/frames");
    let mut names: Vec<String> = fs::read_dir(&directory)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", directory.display()))
        .map(|entry| {
            entry
                .expect("golden directory entry")
                .file_name()
                .to_string_lossy()
                .into_owned()
        })
        .filter(|name| name.ends_with(".json"))
        .collect();
    names.sort();
    let expected: Vec<String> = EXPECTED_GOLDEN_FILES
        .iter()
        .map(|name| (*name).to_owned())
        .collect();
    assert_eq!(
        names, expected,
        "golden/frames must contain exactly the checked vector files"
    );
    assert_eq!(
        names.len() + 1,
        EXPECTED_GOLDEN_VECTORS,
        "32 vector files plus the inline channel.md vector are the 33 vectors"
    );
    names
        .iter()
        .map(|name| load_one(&directory, name))
        .collect()
}

/// Loads one golden vector by file name; the name must be in the fixed set.
pub fn load_golden_file(name: &str) -> GoldenVector {
    assert!(
        EXPECTED_GOLDEN_FILES.contains(&name),
        "golden file {name} is not in the fixed vector list"
    );
    load_one(&spec_root().join("golden/frames"), name)
}

fn load_one(directory: &Path, name: &str) -> GoldenVector {
    let text = fs::read_to_string(directory.join(name))
        .unwrap_or_else(|error| panic!("cannot read golden {name}: {error}"));
    let value: Json = serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("golden {name} is not JSON: {error}"));
    let object = value
        .as_object()
        .unwrap_or_else(|| panic!("golden {name} is not an object"));
    assert_eq!(
        object.len(),
        6,
        "golden {name} has exactly six members (type, type_byte, seq, fields, \
         payload_hex, frame_hex)"
    );
    let type_name = string_member(&value, "type").to_owned();
    let type_byte = u8::try_from(u64_member(&value, "type_byte")).expect("type_byte is a u8");
    let seq = u64_member(&value, "seq");
    let fields = value
        .get("fields")
        .cloned()
        .expect("golden has a fields member");
    let payload_hex = string_member(&value, "payload_hex").to_owned();
    let frame_hex = string_member(&value, "frame_hex").to_owned();
    GoldenVector {
        name: name.to_owned(),
        type_name,
        type_byte,
        seq,
        fields,
        payload: hex_to_bytes(&payload_hex),
        payload_hex,
        frame: hex_to_bytes(&frame_hex),
        frame_hex,
    }
}

/// Builds the semantic frame from a vector's `fields` and `seq`.
///
/// The construction is independent of the crate's decoder: every field is read
/// by name from the golden JSON, so a decoder that loses or swaps a field cannot
/// make this agree by accident.
pub fn frame_from_golden(vector: &GoldenVector) -> Frame {
    let fields = &vector.fields;
    let data = |name: &str| hex_to_bytes(string_member(fields, name));
    match vector.type_byte {
        0x01 => Frame::Hello(json_to_object(fields)),
        0x20 => Frame::ExecReq(json_to_object(fields)),
        0x21 => Frame::ExecEvt(json_to_object(fields)),
        0x22 => Frame::ExecCtl(json_to_object(fields)),
        0x50 => Frame::Lifecycle(json_to_object(fields)),
        0x60 => Frame::Console(json_to_object(fields)),
        0x70 => Frame::Fence(json_to_object(fields)),
        0x7F => Frame::Error(json_to_object(fields)),
        0x10 => {
            assert_members(
                fields,
                &[
                    "append_from",
                    "data_hex",
                    "data_len",
                    "mflags",
                    "mode",
                    "mseq",
                    "op",
                    "path",
                ],
            );
            let data = data("data_hex");
            let data_len = u64_member(fields, "data_len");
            assert_eq!(
                data_len,
                data.len() as u64,
                "{}: fields.data_len must equal the decoded data_hex length",
                vector.name
            );
            Frame::VfsMut(VfsMutation {
                mseq: u64_member(fields, "mseq"),
                op: VfsOp::from_byte(u8_member(fields, "op")).expect("golden op is known"),
                mode: u32_member(fields, "mode"),
                mflags: u8_member(fields, "mflags"),
                append_from: u64_member(fields, "append_from"),
                path: string_member(fields, "path").to_owned(),
                data,
            })
        }
        0x11 => {
            assert_members(fields, &["level", "upto_mseq"]);
            Frame::VfsAck(VfsAck {
                level: AckLevel::from_byte(u8_member(fields, "level")).expect("golden level"),
                upto_mseq: u64_member(fields, "upto_mseq"),
            })
        }
        0x12 => {
            assert_members(fields, &["want_level", "upto_mseq"]);
            Frame::VfsBarrier(VfsBarrier {
                want_level: AckLevel::from_byte(u8_member(fields, "want_level"))
                    .expect("golden want_level"),
                upto_mseq: u64_member(fields, "upto_mseq"),
            })
        }
        0x13 => {
            assert_members(fields, &["path"]);
            Frame::VfsResync(VfsResync {
                path: string_member(fields, "path").to_owned(),
            })
        }
        0x30 => {
            assert_members(fields, &["jseq", "record_hex", "session_id"]);
            Frame::Journal(Journal {
                jseq: u64_member(fields, "jseq"),
                session_id: string_member(fields, "session_id").to_owned(),
                record: data("record_hex"),
            })
        }
        0x31 => {
            assert_members(fields, &["level", "session_id", "upto_jseq"]);
            Frame::JournalAck(JournalAck {
                level: AckLevel::from_byte(u8_member(fields, "level")).expect("golden level"),
                session_id: string_member(fields, "session_id").to_owned(),
                upto_jseq: u64_member(fields, "upto_jseq"),
            })
        }
        0x40 => {
            assert_members(fields, &["body_hex", "head", "req_id"]);
            Frame::ApiReq(ApiRequest {
                req_id: u32_member(fields, "req_id"),
                head: json_to_object(member(fields, "head")),
                body: data("body_hex"),
            })
        }
        0x41 => {
            assert_members(fields, &["body_hex", "head", "req_id"]);
            let head = member(fields, "head");
            Frame::ApiRes(ApiResponse {
                req_id: u32_member(fields, "req_id"),
                head: if head.is_null() {
                    None
                } else {
                    Some(json_to_object(head))
                },
                body: data("body_hex"),
            })
        }
        0x42 => {
            assert_members(fields, &["req_id"]);
            Frame::ApiEnd(ApiEnd {
                req_id: u32_member(fields, "req_id"),
            })
        }
        0x43 => {
            assert_members(fields, &["reason", "req_id"]);
            Frame::ApiAbort(ApiAbort {
                req_id: u32_member(fields, "req_id"),
                reason: string_member(fields, "reason").to_owned(),
            })
        }
        other => panic!("no golden frame builder for type byte 0x{other:02X}"),
    }
}

/// Asserts that a binary payload's `fields` are exactly the documented members.
pub fn assert_members(fields: &Json, expected: &[&str]) {
    let object = fields.as_object().expect("binary fields are an object");
    let mut actual: Vec<&str> = object.keys().map(String::as_str).collect();
    actual.sort_unstable();
    let mut expected_sorted = expected.to_vec();
    expected_sorted.sort_unstable();
    assert_eq!(actual, expected_sorted, "golden fields members");
}

/// Converts a `serde_json` value into the crate's integer-only JSON value.
pub fn json_to_value(value: &Json) -> JsonValue {
    match value {
        Json::Null => JsonValue::Null,
        Json::Bool(boolean) => JsonValue::Bool(*boolean),
        Json::Number(number) => JsonValue::Integer(
            number
                .as_i64()
                .map(i128::from)
                .or_else(|| number.as_u64().map(i128::from))
                .expect("golden numbers are integers in the i64/u64 range"),
        ),
        Json::String(text) => JsonValue::String(text.clone()),
        Json::Array(items) => JsonValue::Array(items.iter().map(json_to_value).collect()),
        Json::Object(members) => JsonValue::Object(json_object_from_map(members)),
    }
}

/// Converts a `serde_json` object into the crate's canonical object.
pub fn json_to_object(value: &Json) -> JsonObject {
    let members = value.as_object().expect("golden value is an object");
    json_object_from_map(members)
}

fn json_object_from_map(members: &serde_json::Map<String, Json>) -> JsonObject {
    let pairs = members
        .iter()
        .map(|(key, value)| (key.clone(), json_to_value(value)))
        .collect::<Vec<_>>();
    JsonObject::from_pairs(pairs).expect("golden objects have no duplicate member")
}

/// The expected `FrameType` of a golden vector.
pub fn frame_type_of(vector: &GoldenVector) -> FrameType {
    FrameType::from_byte(vector.type_byte).expect("golden type byte is one of the 18")
}

/// Lowercase hexadecimal, the form golden vectors use.
pub fn bytes_to_hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;

    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// Decodes a lowercase or uppercase hexadecimal string.
pub fn hex_to_bytes(hex: &str) -> Vec<u8> {
    assert!(hex.len() % 2 == 0, "hex string has an even length");
    (0..hex.len())
        .step_by(2)
        .map(|index| {
            u8::from_str_radix(&hex[index..index + 2], 16)
                .unwrap_or_else(|error| panic!("invalid hex at offset {index}: {error}"))
        })
        .collect()
}

fn member<'a>(fields: &'a Json, name: &str) -> &'a Json {
    fields
        .get(name)
        .unwrap_or_else(|| panic!("golden fields has no {name} member"))
}

fn string_member<'a>(fields: &'a Json, name: &str) -> &'a str {
    member(fields, name)
        .as_str()
        .unwrap_or_else(|| panic!("golden {name} is not a string"))
}

fn u64_member(fields: &Json, name: &str) -> u64 {
    member(fields, name)
        .as_u64()
        .unwrap_or_else(|| panic!("golden {name} is not a u64"))
}

fn u32_member(fields: &Json, name: &str) -> u32 {
    u32::try_from(u64_member(fields, name)).unwrap_or_else(|_| panic!("golden {name} is not a u32"))
}

fn u8_member(fields: &Json, name: &str) -> u8 {
    u8::try_from(u64_member(fields, name)).unwrap_or_else(|_| panic!("golden {name} is not a u8"))
}
