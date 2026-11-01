// SPDX-License-Identifier: MIT
//! Golden-vector conformance of the JNI bridge (the Kotlin suite has the same
//! oracle; this one fails faster while iterating on Rust).
//!
//! Each golden file is fed to `encode_frame` unmodified (the bridge ignores its
//! `seq`, `payload_hex` and `frame_hex` members), the encoded bytes must equal
//! `frame_hex`, and `decode_frame` must return fields equal to the file's
//! `fields`. The set is the 32 files plus the inline `channel.md` §4.8 vector,
//! exactly as the Rust codec suite defines it.

use std::fs;
use std::path::PathBuf;

use pdsh_jni::bridge::{decode_frame, encode_frame};
use pdsh_wire::{JsonObject, JsonValue};

const EXPECTED_GOLDEN_FILES: [&str; 32] = [
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

const INLINE_PAYLOAD_HEX: &str = "7b22636f6465223a225646535f52454655534544222c226c696d6974223a31353732383634302c226d657373616765223a224546424947222c2270617468223a222f6473682f776f726b73706163652f61222c22726561736f6e223a2266696c652d746f6f2d6c61726765227d";
const INLINE_FRAME_HEX: &str = "5a4c7f0000000000000000090000006d7b22636f6465223a225646535f52454655534544222c226c696d6974223a31353732383634302c226d657373616765223a224546424947222c2270617468223a222f6473682f776f726b73706163652f61222c22726561736f6e223a2266696c652d746f6f2d6c61726765227d";
const INLINE_FIELDS: &str = r#"{"code":"VFS_REFUSED","limit":15728640,"message":"EFBIG","path":"/dsh/workspace/a","reason":"file-too-large"}"#;

fn spec_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../spec/v1")
}

#[test]
fn bridge_reproduces_every_golden_frame() {
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
    assert_eq!(
        names, EXPECTED_GOLDEN_FILES,
        "golden/frames must contain exactly the checked vector files"
    );

    let mut checked = 0;
    for name in &names {
        let document = fs::read_to_string(directory.join(name))
            .unwrap_or_else(|error| panic!("cannot read golden {name}: {error}"));
        let vector = parse_golden(name, &document);
        check_vector(name, &document, &vector);
        checked += 1;
    }

    let spec = fs::read_to_string(spec_root().join("channel.md")).expect("channel.md is readable");
    assert!(
        spec.contains(INLINE_PAYLOAD_HEX),
        "channel.md §4.8 payload_hex drifted from the bridge test"
    );
    assert!(
        spec.contains(INLINE_FRAME_HEX),
        "channel.md §4.8 frame_hex drifted from the bridge test"
    );
    let inline_document = format!(r#"{{"type":"ERROR","fields":{INLINE_FIELDS}}}"#);
    let inline_fields = JsonValue::parse(INLINE_FIELDS).expect("inline fields are JSON");
    check_parts(
        "inline-channel-md-error-2",
        "ERROR",
        &inline_document,
        9,
        INLINE_PAYLOAD_HEX,
        INLINE_FRAME_HEX,
        &inline_fields,
    );
    checked += 1;

    assert_eq!(checked, 33, "the golden set is 33 frame vectors");
}

struct Golden {
    type_name: String,
    seq: u64,
    payload_hex: String,
    frame_hex: String,
    fields: JsonValue,
}

fn parse_golden(name: &str, document: &str) -> Golden {
    let value =
        JsonValue::parse(document).unwrap_or_else(|error| panic!("{name} is not JSON: {error}"));
    let object = value
        .as_object()
        .unwrap_or_else(|| panic!("{name} is not a JSON object"));
    assert_eq!(object.len(), 6, "{name}: golden member count");
    let type_name = string_member(name, object, "type");
    let seq = u64_member(name, object, "seq");
    let payload_hex = string_member(name, object, "payload_hex");
    let frame_hex = string_member(name, object, "frame_hex");
    let fields = object
        .get("fields")
        .unwrap_or_else(|| panic!("{name}: no fields member"))
        .clone();
    assert!(
        fields.as_object().is_some(),
        "{name}: fields member is not an object"
    );
    Golden {
        type_name: type_name.to_owned(),
        seq,
        payload_hex: payload_hex.to_owned(),
        frame_hex: frame_hex.to_owned(),
        fields,
    }
}

fn string_member<'a>(name: &str, object: &'a JsonObject, member: &str) -> &'a str {
    object
        .get(member)
        .and_then(JsonValue::as_str)
        .unwrap_or_else(|| panic!("{name}: {member} is not a string"))
}

fn u64_member(name: &str, object: &JsonObject, member: &str) -> u64 {
    object
        .get(member)
        .and_then(JsonValue::as_u64)
        .unwrap_or_else(|| panic!("{name}: {member} is not a u64"))
}

fn check_vector(name: &str, document: &str, golden: &Golden) {
    check_parts(
        name,
        &golden.type_name,
        document,
        golden.seq,
        &golden.payload_hex,
        &golden.frame_hex,
        &golden.fields,
    );
}

fn check_parts(
    name: &str,
    type_name: &str,
    document: &str,
    seq: u64,
    payload_hex: &str,
    frame_hex: &str,
    fields: &JsonValue,
) {
    let expected_frame = hex_to_bytes(frame_hex);
    let expected_payload = hex_to_bytes(payload_hex);

    let encoded = encode_frame(document, seq)
        .unwrap_or_else(|error| panic!("{name}: encode_frame failed: {error}"));
    assert_eq!(bytes_to_hex(&encoded), frame_hex, "{name}: frame_hex");
    assert_eq!(&encoded[16..], &expected_payload[..], "{name}: payload_hex");

    let decoded = decode_frame(&expected_frame)
        .unwrap_or_else(|error| panic!("{name}: decode_frame failed: {error}"));
    let decoded_fields = JsonValue::parse(&decoded)
        .unwrap_or_else(|error| panic!("{name}: decoded fields are not JSON: {error}"));
    assert_eq!(&decoded_fields, fields, "{name}: decoded fields");

    // The decoded fields wrapped with the frame type must re-encode to the
    // same bytes; this is the round trip the Kotlin suite asserts.
    let envelope = format!(r#"{{"type":"{type_name}","fields":{decoded}}}"#);
    let re_encoded = encode_frame(&envelope, seq)
        .unwrap_or_else(|error| panic!("{name}: re-encode failed: {error}"));
    assert_eq!(bytes_to_hex(&re_encoded), frame_hex, "{name}: re-encoded");
}

fn hex_to_bytes(hex: &str) -> Vec<u8> {
    assert_eq!(hex.len() % 2, 0, "odd hex length");
    hex.as_bytes()
        .chunks(2)
        .map(|pair| {
            let high = (pair[0] as char).to_digit(16).expect("hex digit") as u8;
            let low = (pair[1] as char).to_digit(16).expect("hex digit") as u8;
            (high << 4) | low
        })
        .collect()
}

fn bytes_to_hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &byte in bytes {
        out.push(char::from(DIGITS[usize::from(byte >> 4)]));
        out.push(char::from(DIGITS[usize::from(byte & 0x0F)]));
    }
    out
}
