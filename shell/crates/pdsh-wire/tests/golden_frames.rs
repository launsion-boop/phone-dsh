// SPDX-License-Identifier: MIT
//! Conformance with the phone-dsh-v1 golden frame vectors.
//!
//! For every vector: decode `frame_hex` successfully, compare the decoded
//! payload with the semantic `fields`, and re-encode from `fields` and `seq` to
//! exactly `payload_hex` and `frame_hex` (`golden/README.md` §1). The set is
//! fixed at 35 vectors: the 34 files plus the inline `channel.md` §4.8 golden.
//!
//! Each of the 34 files is its own `#[test]`, so a passing run lists 34 vector
//! names plus the inline 35th instead of hiding them behind one loop.

#![forbid(unsafe_code)]

mod common;

use common::{
    bytes_to_hex, frame_from_golden, hex_to_bytes, load_golden_file, load_golden_vectors,
    spec_root, GoldenVector, EXPECTED_GOLDEN_FILES, EXPECTED_GOLDEN_VECTORS,
};
use pdsh_wire::{decode, decode_with_header, Frame, FrameType, Header, JsonObject};

/// The inline `channel.md` §4.8 golden frame: `ERROR VFS_REFUSED` at `seq = 9`.
const INLINE_PAYLOAD_HEX: &str = "7b22636f6465223a225646535f52454655534544222c226c696d6974223a31353732383634302c226d657373616765223a224546424947222c2270617468223a222f6473682f776f726b73706163652f61222c22726561736f6e223a2266696c652d746f6f2d6c61726765227d";
const INLINE_FRAME_HEX: &str = "5a4c7f0000000000000000090000006d7b22636f6465223a225646535f52454655534544222c226c696d6974223a31353732383634302c226d657373616765223a224546424947222c2270617468223a222f6473682f776f726b73706163652f61222c22726561736f6e223a2266696c652d746f6f2d6c61726765227d";
const INLINE_SEQ: u64 = 9;
const INLINE_FIELDS: &str = r#"{"code":"VFS_REFUSED","limit":15728640,"message":"EFBIG","path":"/dsh/workspace/a","reason":"file-too-large"}"#;

/// Asserts the byte-for-byte contract of one golden vector.
fn check_vector(vector: &GoldenVector) {
    let frame = frame_from_golden(vector);
    assert_eq!(
        frame.frame_type().byte(),
        vector.type_byte,
        "{}: type byte",
        vector.name
    );
    assert_eq!(
        frame.frame_type().name(),
        vector.type_name,
        "{}: type name",
        vector.name
    );

    let payload = frame
        .encode_payload()
        .unwrap_or_else(|error| panic!("{}: encode_payload failed: {error}", vector.name));
    assert_eq!(
        bytes_to_hex(&payload),
        vector.payload_hex,
        "{}: payload_hex",
        vector.name
    );

    let encoded = frame
        .encode(vector.seq)
        .unwrap_or_else(|error| panic!("{}: encode failed: {error}", vector.name));
    assert_eq!(
        bytes_to_hex(&encoded),
        vector.frame_hex,
        "{}: frame_hex",
        vector.name
    );

    let (header, decoded) = decode_with_header(&vector.frame)
        .unwrap_or_else(|error| panic!("{}: decode_with_header failed: {error}", vector.name));
    assert_eq!(
        header.type_byte, vector.type_byte,
        "{}: header type",
        vector.name
    );
    assert_eq!(header.flags, 0, "{}: flags are zero", vector.name);
    assert_eq!(header.seq, vector.seq, "{}: header seq", vector.name);
    assert_eq!(
        header.len as usize,
        vector.payload.len(),
        "{}: header len",
        vector.name
    );
    assert_eq!(
        decoded, frame,
        "{}: the decoded payload must equal the golden fields",
        vector.name
    );
    assert_eq!(
        decoded
            .encode_payload()
            .unwrap_or_else(|error| panic!("{}: re-encode failed: {error}", vector.name)),
        vector.payload,
        "{}: re-encoded payload",
        vector.name
    );
    assert_eq!(
        decoded
            .encode(vector.seq)
            .unwrap_or_else(|error| panic!("{}: re-encode frame failed: {error}", vector.name)),
        vector.frame,
        "{}: re-encoded frame",
        vector.name
    );
    assert_eq!(
        decode(&vector.frame).expect("decode"),
        frame,
        "{}: decode",
        vector.name
    );
}

macro_rules! golden_frame_tests {
    ($($test_name:ident => $file:literal),+ $(,)?) => {
        $(
            #[test]
            fn $test_name() {
                let vector = load_golden_file($file);
                check_vector(&vector);
            }
        )+
    };
}

golden_frame_tests! {
    golden_01_api_abort_1 => "api-abort-1.json",
    golden_02_api_end_1 => "api-end-1.json",
    golden_03_api_req_1 => "api-req-1.json",
    golden_04_api_res_1 => "api-res-1.json",
    golden_05_api_res_continuation_1 => "api-res-continuation-1.json",
    golden_06_api_res_empty_body_1 => "api-res-empty-body-1.json",
    golden_07_console_1 => "console-1.json",
    golden_08_console_2 => "console-2.json",
    golden_09_error_1 => "error-1.json",
    golden_10_error_2 => "error-2.json",
    golden_11_error_3 => "error-3.json",
    golden_12_exec_ctl_1 => "exec-ctl-1.json",
    golden_13_exec_ctl_2 => "exec-ctl-2.json",
    golden_14_exec_evt_1 => "exec-evt-1.json",
    golden_15_exec_evt_2 => "exec-evt-2.json",
    golden_16_exec_req_1 => "exec-req-1.json",
    golden_17_fence_1 => "fence-1.json",
    golden_18_hello_host_1 => "hello-host-1.json",
    golden_19_hello_worker_1 => "hello-worker-1.json",
    golden_20_journal_1 => "journal-1.json",
    golden_21_journal_ack_1 => "journal-ack-1.json",
    golden_22_lifecycle_1 => "lifecycle-1.json",
    golden_23_vfs_ack_1 => "vfs-ack-1.json",
    golden_24_vfs_ack_2 => "vfs-ack-2.json",
    golden_25_vfs_barrier_1 => "vfs-barrier-1.json",
    golden_26_vfs_mut_append_1 => "vfs-mut-append-1.json",
    golden_27_vfs_mut_binary_1 => "vfs-mut-binary-1.json",
    golden_28_vfs_mut_chmod_1 => "vfs-mut-chmod-1.json",
    golden_29_vfs_mut_mkdir_1 => "vfs-mut-mkdir-1.json",
    golden_30_vfs_mut_remove_1 => "vfs-mut-remove-1.json",
    golden_31_vfs_mut_write_1 => "vfs-mut-write-1.json",
    golden_32_vfs_resync_1 => "vfs-resync-1.json",
    golden_33_exec_req_2 => "exec-req-2.json",
    golden_34_exec_req_3 => "exec-req-3.json",
}

#[test]
fn golden_35_inline_channel_md_error_vector() {
    let spec =
        std::fs::read_to_string(spec_root().join("channel.md")).expect("channel.md is readable");
    assert!(
        spec.contains(INLINE_PAYLOAD_HEX),
        "the channel.md §4.8 payload_hex drifted from the codec test"
    );
    assert!(
        spec.contains(INLINE_FRAME_HEX),
        "the channel.md §4.8 frame_hex drifted from the codec test"
    );

    let object = JsonObject::parse(INLINE_FIELDS).expect("inline fields parse");
    let frame = Frame::Error(object);
    assert_eq!(
        bytes_to_hex(&frame.encode_payload().expect("inline payload")),
        INLINE_PAYLOAD_HEX
    );
    assert_eq!(
        frame.encode(INLINE_SEQ).expect("inline frame"),
        hex_to_bytes(INLINE_FRAME_HEX)
    );
    assert_eq!(
        decode(&hex_to_bytes(INLINE_FRAME_HEX)).expect("inline decode"),
        frame
    );
}

#[test]
fn golden_set_is_fixed_at_35_vectors() {
    let vectors = load_golden_vectors();
    assert_eq!(EXPECTED_GOLDEN_FILES.len(), 34);
    assert_eq!(vectors.len() + 1, EXPECTED_GOLDEN_VECTORS);
    assert_eq!(EXPECTED_GOLDEN_VECTORS, 35);
    for frame_type in FrameType::ALL {
        assert!(
            vectors
                .iter()
                .any(|vector| vector.type_byte == frame_type.byte()),
            "golden/frames has no vector for {} (0x{:02X})",
            frame_type.name(),
            frame_type.byte()
        );
    }
    for vector in &vectors {
        let frame_type =
            FrameType::from_byte(vector.type_byte).expect("golden type byte is one of the 18");
        assert_eq!(
            frame_type.name(),
            vector.type_name,
            "{}: type byte matches the type name",
            vector.name
        );
    }
}

#[test]
fn json_variants_are_accepted_and_reencode_to_the_golden_bytes() {
    let vectors = load_golden_vectors();
    let find = |name: &str| {
        vectors
            .iter()
            .find(|vector| vector.name == name)
            .unwrap_or_else(|| panic!("missing golden {name}"))
    };

    // Reordered members, arbitrary whitespace and an escaped member name.
    assert_variant_reencodes(
        find("lifecycle-1.json"),
        br#"{
            "state" : "run",
            "reason": "foreground" , "budget" : 120000,
            "admission": "\u006fpen"
        }"#,
    );

    // The golden stores a literal check mark; this variant uses the \u escape.
    assert_variant_reencodes(
        find("console-2.json"),
        br#"{ "text" : "ready \u2713" , "level" : "info" }"#,
    );

    // Pretty-printed members with every slash escaped as \/.
    let error3 = find("error-3.json");
    let pretty = serde_json::to_string_pretty(&error3.fields).expect("pretty JSON");
    let escaped_slashes = pretty.replace('/', "\\/");
    assert_variant_reencodes(error3, escaped_slashes.as_bytes());
}

fn assert_variant_reencodes(vector: &GoldenVector, variant_payload: &[u8]) {
    let expected = frame_from_golden(vector);
    let header = Header::new(vector.type_byte, vector.seq, variant_payload.len())
        .unwrap_or_else(|error| panic!("{}: variant header: {error}", vector.name));
    let mut bytes = header.emit().to_vec();
    bytes.extend_from_slice(variant_payload);

    let decoded = decode(&bytes)
        .unwrap_or_else(|error| panic!("{}: variant must decode: {error}", vector.name));
    assert_eq!(
        decoded, expected,
        "{}: the variant is semantically equal to the golden fields",
        vector.name
    );
    assert_eq!(
        decoded
            .encode_payload()
            .unwrap_or_else(|error| panic!("{}: variant re-encode: {error}", vector.name)),
        vector.payload,
        "{}: re-encode returns the golden payload bytes",
        vector.name
    );
    assert_eq!(
        decoded
            .encode(vector.seq)
            .unwrap_or_else(|error| panic!("{}: variant frame re-encode: {error}", vector.name)),
        vector.frame,
        "{}: re-encode returns the golden frame bytes",
        vector.name
    );
}
