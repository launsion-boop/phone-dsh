// SPDX-License-Identifier: MIT
//! Boundary and error-path tests for the frame codec: CRC32C known answer,
//! header round trip, unknown type bytes, the 16 MiB payload bound, length
//! fields, UTF-8, canonical JSON rules and the §10 codes.

#![forbid(unsafe_code)]

mod common;

use common::{bytes_to_hex, hex_to_bytes};
use pdsh_wire::{
    crc32c, decode, decode_with_header, AckLevel, ApiAbort, ApiEnd, ApiRequest, ApiResponse,
    Direction, ErrorCode, Frame, FrameType, Header, Journal, JournalAck, JsonObject, JsonValue,
    VfsAck, VfsBarrier, VfsMutation, VfsOp, VfsResync, WireError, HEADER_LEN, MAX_API_BODY_LEN,
    MAX_MUTATION_DATA_LEN, MAX_PAYLOAD_LEN, MFLAGS_ALL, MFLAG_ENTRY_CHANGED,
};

fn vfs_ack_frame(seq: u64) -> Vec<u8> {
    Frame::VfsAck(VfsAck {
        level: AckLevel::Write,
        upto_mseq: 7,
    })
    .encode(seq)
    .expect("VFS_ACK frame encodes")
}

fn mutation(data: Vec<u8>) -> VfsMutation {
    VfsMutation {
        mseq: 1,
        op: VfsOp::Write,
        mode: 0o644,
        mflags: MFLAG_ENTRY_CHANGED,
        append_from: 0,
        path: "/dsh/workspace/a".to_owned(),
        data,
    }
}

#[test]
fn crc32c_known_answer() {
    assert_eq!(crc32c(b"123456789"), 0xE306_9283);
    assert_eq!(crc32c(b""), 0);
    assert_eq!(crc32c(b"a"), 0xC1D0_4330);
}

#[test]
fn header_matches_the_hand_computed_constant() {
    let constant = hex_to_bytes("5a4c1100000000000000000100000009");
    let header = Header::parse(&constant).expect("the §1 hand-computed header parses");
    assert_eq!(header.type_byte, 0x11);
    assert_eq!(header.flags, 0);
    assert_eq!(header.seq, 1);
    assert_eq!(header.len, 9);
    assert_eq!(header.total_len(), 25);
    assert_eq!(header.emit().to_vec(), constant);
    assert_eq!(
        Header::new(0x11, 1, 9).expect("header").emit().to_vec(),
        constant
    );
    assert_eq!(
        bytes_to_hex(&vfs_ack_frame(1)[..HEADER_LEN]),
        "5a4c1100000000000000000100000009"
    );
}

#[test]
fn header_rejects_bad_magic_flags_and_lengths() {
    let constant = hex_to_bytes("5a4c1100000000000000000100000009");

    let mut magic = constant.clone();
    magic[1] = 0x4d;
    assert_eq!(
        Header::parse(&magic).expect_err("bad magic").code(),
        ErrorCode::BadMagic
    );

    let mut flags = constant.clone();
    flags[3] = 0x01;
    assert_eq!(
        Header::parse(&flags).expect_err("flags").code(),
        ErrorCode::BadPayload
    );

    let mut zero = constant.clone();
    zero[12..16].copy_from_slice(&0u32.to_be_bytes());
    assert_eq!(
        Header::parse(&zero).expect_err("zero len").code(),
        ErrorCode::BadPayload
    );

    let mut too_long = constant.clone();
    too_long[12..16].copy_from_slice(&(MAX_PAYLOAD_LEN as u32 + 1).to_be_bytes());
    assert_eq!(
        Header::parse(&too_long).expect_err("len bound").code(),
        ErrorCode::BadPayload
    );

    assert_eq!(
        Header::parse(&constant[..HEADER_LEN - 1])
            .expect_err("short header")
            .code(),
        ErrorCode::BadPayload
    );
}

#[test]
fn decode_rejects_unknown_type_trailing_and_truncated_frames() {
    let frame = vfs_ack_frame(1);

    let mut unknown = frame.clone();
    unknown[2] = 0x55;
    assert_eq!(
        decode(&unknown).expect_err("unknown type").code(),
        ErrorCode::BadPayload
    );

    let mut trailing = frame.clone();
    trailing.push(0);
    assert_eq!(
        decode(&trailing).expect_err("trailing").code(),
        ErrorCode::BadPayload
    );

    assert_eq!(
        decode(&frame[..frame.len() - 1])
            .expect_err("truncated")
            .code(),
        ErrorCode::BadPayload
    );
    assert_eq!(
        decode(&frame[..HEADER_LEN - 4]).expect_err("short").code(),
        ErrorCode::BadPayload
    );

    let mut bad_level = vfs_ack_frame(5);
    bad_level[HEADER_LEN] = 3;
    let error = decode(&bad_level).expect_err("bad level");
    assert_eq!(error.code(), ErrorCode::BadPayload);
    assert_eq!(error.ref_seq(), Some(5));

    let mut frame_with_flags = frame.clone();
    frame_with_flags[3] = 1;
    assert_eq!(
        decode(&frame_with_flags).expect_err("flags").code(),
        ErrorCode::BadPayload
    );
}

#[test]
fn encode_rejects_zero_seq_and_payloads_above_sixteen_mib() {
    let ack = Frame::VfsAck(VfsAck {
        level: AckLevel::Write,
        upto_mseq: 1,
    });
    assert_eq!(ack.encode(0).expect_err("seq 0").code(), ErrorCode::BadSeq);

    assert_eq!(
        Header::new(0x60, 1, MAX_PAYLOAD_LEN + 1)
            .expect_err("len above the cap")
            .code(),
        ErrorCode::BadPayload
    );
    assert_eq!(
        Header::new(0x60, 1, 0).expect_err("zero len").code(),
        ErrorCode::BadPayload
    );
    assert!(Header::new(0x60, 1, MAX_PAYLOAD_LEN).is_ok());

    let mut object = JsonObject::new();
    object.insert("text", JsonValue::String("x".repeat(MAX_PAYLOAD_LEN)));
    let error = Frame::Console(object)
        .encode(1)
        .expect_err("payload above the cap");
    assert_eq!(error.code(), ErrorCode::BadPayload);
}

#[test]
fn mutation_rejects_reserved_flags_zero_mseq_and_unknown_op() {
    let mut reserved = mutation(Vec::new());
    reserved.mflags = MFLAGS_ALL | 0x04;
    assert_eq!(
        reserved.encode().expect_err("reserved flags").code(),
        ErrorCode::BadPayload
    );

    let mut zero = mutation(Vec::new());
    zero.mseq = 0;
    assert_eq!(
        zero.encode().expect_err("mseq 0").code(),
        ErrorCode::BadMseq
    );

    let mut payload = mutation(b"hi".to_vec()).encode().expect("encode");
    payload[8] = 9;
    assert_eq!(
        VfsMutation::decode(&payload).expect_err("op").code(),
        ErrorCode::BadPayload
    );

    let mut zero_mseq = mutation(b"hi".to_vec()).encode().expect("encode");
    zero_mseq[..8].copy_from_slice(&0u64.to_be_bytes());
    assert_eq!(
        VfsMutation::decode(&zero_mseq).expect_err("mseq").code(),
        ErrorCode::BadMseq
    );

    let mut reserved_flags = mutation(b"hi".to_vec()).encode().expect("encode");
    reserved_flags[13] = 0x80;
    assert_eq!(
        VfsMutation::decode(&reserved_flags)
            .expect_err("flags")
            .code(),
        ErrorCode::BadPayload
    );
}

#[test]
fn mutation_rejects_length_and_utf8_violations() {
    let encoded = mutation(b"hi".to_vec()).encode().expect("encode");
    let path_len = usize::from(u16::from_be_bytes([encoded[22], encoded[23]]));
    let data_len_at = 24 + path_len;
    assert_eq!(&encoded[data_len_at..data_len_at + 4], &2u32.to_be_bytes());

    let mut wrong_len = encoded.clone();
    wrong_len[data_len_at..data_len_at + 4].copy_from_slice(&3u32.to_be_bytes());
    assert_eq!(
        VfsMutation::decode(&wrong_len)
            .expect_err("data_len mismatch")
            .code(),
        ErrorCode::BadPayload
    );

    let mut bad_utf8 = encoded.clone();
    bad_utf8[24] = 0xFF;
    assert_eq!(
        VfsMutation::decode(&bad_utf8)
            .expect_err("invalid UTF-8 path")
            .code(),
        ErrorCode::BadPayload
    );

    let mut trailing = encoded;
    trailing.push(0);
    assert_eq!(
        VfsMutation::decode(&trailing).expect_err("trailing").code(),
        ErrorCode::BadPayload
    );

    let oversized = mutation(vec![0u8; MAX_MUTATION_DATA_LEN + 1]);
    assert_eq!(
        oversized.encode().expect_err("15 MiB bound").code(),
        ErrorCode::BadPayload
    );
}

#[test]
fn ack_levels_must_be_one_or_two() {
    let mut payload = VfsAck {
        level: AckLevel::Write,
        upto_mseq: 1,
    }
    .encode();
    payload[0] = 3;
    assert_eq!(
        VfsAck::decode(&payload).expect_err("ack level").code(),
        ErrorCode::BadPayload
    );

    let mut barrier = VfsBarrier {
        want_level: AckLevel::EpochFsync,
        upto_mseq: 1,
    }
    .encode();
    barrier[0] = 0;
    assert_eq!(
        VfsBarrier::decode(&barrier)
            .expect_err("barrier level")
            .code(),
        ErrorCode::BadPayload
    );

    let ack = VfsAck {
        level: AckLevel::EpochFsync,
        upto_mseq: 9,
    };
    assert_eq!(VfsAck::decode(&ack.encode()).expect("round trip"), ack);
}

#[test]
fn journal_requires_a_record_and_a_nonzero_jseq() {
    let journal = Journal {
        jseq: 1,
        session_id: "sess_01".to_owned(),
        record: vec![1, 2, 3],
    };
    let encoded = journal.encode().expect("encode");
    assert_eq!(Journal::decode(&encoded).expect("decode"), journal);

    let empty = Journal {
        jseq: 1,
        session_id: "sess_01".to_owned(),
        record: Vec::new(),
    };
    assert_eq!(
        empty.encode().expect_err("empty record").code(),
        ErrorCode::BadPayload
    );

    let mut zero = encoded.clone();
    zero[..8].copy_from_slice(&0u64.to_be_bytes());
    assert_eq!(
        Journal::decode(&zero).expect_err("jseq").code(),
        ErrorCode::BadPayload
    );

    let session_len = usize::from(u16::from_be_bytes([encoded[8], encoded[9]]));
    assert_eq!(
        Journal::decode(&encoded[..10 + session_len])
            .expect_err("no record")
            .code(),
        ErrorCode::BadPayload
    );

    let ack = JournalAck {
        level: AckLevel::Write,
        session_id: "sess_01".to_owned(),
        upto_jseq: 1,
    };
    let mut encoded_ack = ack.encode().expect("ack encode");
    assert_eq!(JournalAck::decode(&encoded_ack).expect("ack"), ack);
    encoded_ack.push(0);
    assert_eq!(
        JournalAck::decode(&encoded_ack)
            .expect_err("trailing")
            .code(),
        ErrorCode::BadPayload
    );
}

#[test]
fn resync_path_must_be_utf8() {
    assert_eq!(
        VfsResync::decode(&[0x00, 0x02, 0xFF, 0xFE])
            .expect_err("invalid UTF-8")
            .code(),
        ErrorCode::BadPayload
    );
    let resync = VfsResync {
        path: "/dsh/workspace/notes.txt".to_owned(),
    };
    assert_eq!(
        VfsResync::decode(&resync.encode().expect("encode")).expect("decode"),
        resync
    );
}

#[test]
fn api_frames_enforce_their_structural_fields() {
    let head = JsonObject::parse(r#"{"headers":{},"method":"GET","path":"/"}"#).expect("head");
    let request = ApiRequest {
        req_id: 7,
        head: head.clone(),
        body: vec![1, 2],
    };
    let encoded = request.encode().expect("encode");
    assert_eq!(ApiRequest::decode(&encoded).expect("decode"), request);

    let mut no_head = encoded.clone();
    no_head[4..8].copy_from_slice(&0u32.to_be_bytes());
    assert_eq!(
        ApiRequest::decode(&no_head).expect_err("head_len 0").code(),
        ErrorCode::BadPayload
    );

    let body_too_large = ApiRequest {
        req_id: 7,
        head: head.clone(),
        body: vec![0u8; MAX_API_BODY_LEN + 1],
    };
    assert_eq!(
        body_too_large.encode().expect_err("body cap").code(),
        ErrorCode::BadPayload
    );

    let head_bytes = head.to_canonical_bytes();
    let mut payload = 1u32.to_be_bytes().to_vec();
    payload.extend_from_slice(&(head_bytes.len() as u32).to_be_bytes());
    payload.extend_from_slice(&head_bytes);
    payload.resize(payload.len() + MAX_API_BODY_LEN + 1, 0);
    assert_eq!(
        ApiRequest::decode(&payload).expect_err("body cap").code(),
        ErrorCode::BadPayload
    );

    let continuation = ApiResponse {
        req_id: 7,
        head: None,
        body: b"done\n".to_vec(),
    };
    let encoded = continuation.encode().expect("encode");
    assert_eq!(&encoded[4..8], &0u32.to_be_bytes());
    assert_eq!(ApiResponse::decode(&encoded).expect("decode"), continuation);

    let response_head = JsonObject::parse(r#"{"headers":{},"status":204}"#).expect("head");
    let first_chunk = ApiResponse {
        req_id: 8,
        head: Some(response_head),
        body: Vec::new(),
    };
    let encoded = first_chunk.encode().expect("encode");
    assert_eq!(ApiResponse::decode(&encoded).expect("decode"), first_chunk);

    let mut overrun = encoded;
    overrun[4..8].copy_from_slice(&u32::MAX.to_be_bytes());
    assert_eq!(
        ApiResponse::decode(&overrun).expect_err("overrun").code(),
        ErrorCode::BadPayload
    );

    assert_eq!(
        ApiEnd::decode(&[0, 0, 0, 7]).expect("4-byte API_END"),
        ApiEnd { req_id: 7 }
    );
    assert_eq!(
        ApiEnd::decode(&[0, 0, 0, 7, 0])
            .expect_err("API_END length")
            .code(),
        ErrorCode::BadPayload
    );

    let abort = ApiAbort {
        req_id: 7,
        reason: "connection_closed".to_owned(),
    };
    assert_eq!(ApiAbort::decode(&abort.encode()).expect("abort"), abort);

    let mut missing_reason = 7u32.to_be_bytes().to_vec();
    missing_reason.extend_from_slice(br#"{"why":"x"}"#);
    assert_eq!(
        ApiAbort::decode(&missing_reason)
            .expect_err("missing reason")
            .code(),
        ErrorCode::BadPayload
    );

    let mut wrong_reason = 7u32.to_be_bytes().to_vec();
    wrong_reason.extend_from_slice(br#"{"reason":1}"#);
    assert_eq!(
        ApiAbort::decode(&wrong_reason)
            .expect_err("reason type")
            .code(),
        ErrorCode::BadPayload
    );
}

#[test]
fn json_rejects_duplicates_floats_malformed_and_non_objects() {
    for text in [
        r#"{"a":1,"a":2}"#,
        r#"{"a":1.0}"#,
        r#"{"a":1e3}"#,
        r#"{"a":}"#,
        r#"{"a":1"#,
        "",
    ] {
        assert_eq!(
            JsonValue::parse(text).expect_err("must be rejected").code(),
            ErrorCode::BadPayload,
            "text {text:?}"
        );
    }
}

#[test]
fn json_frames_reject_bad_utf8_non_objects_and_duplicates() {
    let cases: [&[u8]; 4] = [&[0xFF], b"[1]", br#"{"a":1,"a":2}"#, br#"{"a":1.5}"#];
    for payload in cases {
        let header = Header::new(0x70, 1, payload.len()).expect("header");
        let mut frame = header.emit().to_vec();
        frame.extend_from_slice(payload);
        assert_eq!(
            decode(&frame).expect_err("JSON frame payload").code(),
            ErrorCode::BadPayload,
            "payload {payload:?}"
        );
    }
}

#[test]
fn json_accepts_legal_variants() {
    let value = JsonValue::parse(r#""\u00e9 \ud83d\ude00 \/""#).expect("escapes");
    assert_eq!(value.as_str(), Some("é 😀 /"));
    assert_eq!(value.to_canonical_json(), "\"é 😀 /\"");

    let negative_zero = JsonValue::parse("-0").expect("negative zero is an integer");
    assert_eq!(negative_zero, JsonValue::Integer(0));
    assert_eq!(negative_zero.to_canonical_json(), "0");

    let controls = JsonValue::parse(r#""\u0001\u001f""#).expect("controls");
    assert_eq!(controls.to_canonical_json(), "\"\\u0001\\u001f\"");

    assert!(JsonValue::parse(r#""\ud83d""#).is_err());
    assert!(JsonValue::parse(r#""\udc00""#).is_err());
    assert!(JsonValue::parse("\"raw\u{0001}\"").is_err());
}

#[test]
fn canonical_json_escaping_matches_section_five() {
    let mut object = JsonObject::new();
    object.insert(
        "text",
        JsonValue::String("/\"\\\u{08}\u{0c}\n\r\t\u{01}\u{7f}é".to_owned()),
    );
    let encoded = object.to_canonical_json();
    assert!(encoded.contains("\\\""), "quote is escaped: {encoded:?}");
    assert!(
        encoded.contains("\\\\"),
        "backslash is escaped: {encoded:?}"
    );
    assert!(encoded.contains("\\b"), "backspace: {encoded:?}");
    assert!(encoded.contains("\\f"), "form feed: {encoded:?}");
    assert!(encoded.contains("\\n"), "newline: {encoded:?}");
    assert!(encoded.contains("\\r"), "carriage return: {encoded:?}");
    assert!(encoded.contains("\\t"), "tab: {encoded:?}");
    assert!(encoded.contains("\\u0001"), "control: {encoded:?}");
    assert!(encoded.contains('\u{7f}'), "DEL stays literal: {encoded:?}");
    assert!(
        encoded.contains('é'),
        "non-ASCII stays literal: {encoded:?}"
    );
    assert!(
        !encoded.contains("\\/"),
        "slash is never escaped: {encoded:?}"
    );
}

#[test]
fn object_members_sort_by_code_point() {
    let mut object = JsonObject::new();
    for key in ["z", "a", "é", "Z", "0"] {
        object.insert(key, JsonValue::Bool(true));
    }
    let keys: Vec<&str> = object.iter().map(|(key, _)| key).collect();
    assert_eq!(keys, ["0", "Z", "a", "z", "é"]);
    assert_eq!(
        object.to_canonical_json(),
        "{\"0\":true,\"Z\":true,\"a\":true,\"z\":true,\"é\":true}"
    );
}

#[test]
fn direction_table_matches_section_two() {
    let cases = [
        (FrameType::Hello, Direction::Both),
        (FrameType::VfsMut, Direction::WorkerToHost),
        (FrameType::VfsAck, Direction::HostToWorker),
        (FrameType::VfsBarrier, Direction::WorkerToHost),
        (FrameType::VfsResync, Direction::HostToWorker),
        (FrameType::ExecReq, Direction::WorkerToHost),
        (FrameType::ExecEvt, Direction::HostToWorker),
        (FrameType::ExecCtl, Direction::WorkerToHost),
        (FrameType::Journal, Direction::WorkerToHost),
        (FrameType::JournalAck, Direction::HostToWorker),
        (FrameType::ApiReq, Direction::HostToWorker),
        (FrameType::ApiRes, Direction::WorkerToHost),
        (FrameType::ApiEnd, Direction::WorkerToHost),
        (FrameType::ApiAbort, Direction::Both),
        (FrameType::Lifecycle, Direction::HostToWorker),
        (FrameType::Console, Direction::WorkerToHost),
        (FrameType::Fence, Direction::HostToWorker),
        (FrameType::Error, Direction::Both),
    ];
    assert_eq!(cases.len(), FrameType::ALL.len());
    for (frame_type, direction) in cases {
        assert_eq!(frame_type.direction(), direction, "{}", frame_type.name());
    }

    assert!(Direction::Both.allows_host_to_worker());
    assert!(Direction::Both.allows_worker_to_host());
    assert!(Direction::WorkerToHost.allows_worker_to_host());
    assert!(!Direction::WorkerToHost.allows_host_to_worker());
    assert!(Direction::HostToWorker.allows_host_to_worker());
    assert!(!Direction::HostToWorker.allows_worker_to_host());

    let json_count = FrameType::ALL
        .iter()
        .filter(|frame_type| frame_type.has_json_payload())
        .count();
    assert_eq!(json_count, 8);
    for frame_type in FrameType::ALL {
        assert_eq!(FrameType::from_byte(frame_type.byte()), Some(frame_type));
    }
    assert_eq!(FrameType::from_byte(0x55), None);
}

#[test]
fn error_codes_are_the_ten_of_section_ten() {
    let names: Vec<&str> = ErrorCode::ALL.iter().map(|code| code.as_str()).collect();
    assert_eq!(
        names,
        [
            "BAD_MAGIC",
            "BAD_SEQ",
            "BAD_MSEQ",
            "BAD_PATH",
            "BAD_PAYLOAD",
            "FENCE_STALE",
            "VFS_CONFLICT",
            "VFS_REFUSED",
            "RING_TIMEOUT",
            "PROTO_MISMATCH",
        ]
    );
    for code in ErrorCode::ALL {
        assert_eq!(
            code.closes_connection(),
            code != ErrorCode::VfsRefused,
            "{code}"
        );
    }

    let path = WireError::bad_path("/etc/passwd");
    assert_eq!(path.code(), ErrorCode::BadPath);
    assert!(path.to_string().starts_with("BAD_PATH: "));

    let mismatch = WireError::proto_mismatch("second HELLO").with_ref_seq(4);
    assert_eq!(mismatch.code(), ErrorCode::ProtoMismatch);
    assert_eq!(mismatch.ref_seq(), Some(4));
    assert!(mismatch.to_string().ends_with("(ref_seq 4)"));

    assert_eq!(
        decode_with_header(&[0u8; 3]).expect_err("short").code(),
        ErrorCode::BadPayload
    );
}
