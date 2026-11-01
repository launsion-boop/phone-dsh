// SPDX-License-Identifier: MIT
//! Golden-vector conformance of the WAL JNI bridge, byte for byte.
//!
//! `spec/v1/golden/wal/*.json` carries `header.header_hex`, one
//! `records[].record_hex` per record and `file_hex` = header followed by every
//! record. Each vector is fed to `scan_segment` and `classify_tail` as the exact
//! `file_hex` bytes, and the JSON the bridge returns is pinned verbatim.
//!
//! The two vectors are fixed on purpose: a vector that silently disappears, or
//! a scan that silently skips records, fails the test.

mod common;

use std::fs;

use common::{
    golden_file, golden_header, golden_records, golden_vector, golden_wal_dir, hex_decode,
    hex_encode, parse_json, string_member,
};
use pdsh_jni::wal::{classify_tail, decode_record, records, scan_segment, verify_record};
use pdsh_wal::json::Json;
use pdsh_wal::WalError;

const SEGMENT_1: &str = "segment-1.json";
const SEGMENT_EPOCH_ONLY: &str = "segment-epoch-only.json";

const SEGMENT_1_SCAN: &str = concat!(
    r#"{"header_ok":true,"corrupt":false,"first_mseq":42,"first_mutation_mseq":42,"#,
    r#""last_mutation_mseq":46,"epoch_close":46,"torn_tail":null,"chain_error":null,"#,
    r#""header_error":null,"valid_len":377}"#
);

const EPOCH_ONLY_SCAN: &str = concat!(
    r#"{"header_ok":true,"corrupt":false,"first_mseq":88,"first_mutation_mseq":null,"#,
    r#""last_mutation_mseq":0,"epoch_close":87,"torn_tail":null,"chain_error":null,"#,
    r#""header_error":null,"valid_len":73}"#
);

#[test]
fn golden_wal_directory_holds_exactly_two_vectors() {
    let directory = golden_wal_dir();
    let mut names: Vec<String> = fs::read_dir(&directory)
        .expect("the golden WAL directory exists")
        .map(|entry| {
            entry
                .expect("directory entry")
                .file_name()
                .to_string_lossy()
                .into_owned()
        })
        .filter(|name| name.ends_with(".json"))
        .collect();
    names.sort();
    assert_eq!(
        names,
        vec![SEGMENT_1.to_string(), SEGMENT_EPOCH_ONLY.to_string()],
        "expected exactly 2 golden WAL vectors in {}",
        directory.display()
    );
}

/// `segment-1.json`: 5 mutations then the epoch close, byte for byte.
#[test]
fn golden_segment_1_scans_clean_and_is_byte_exact() {
    let file = golden_file(SEGMENT_1);
    let records = golden_records(SEGMENT_1);
    let header = golden_header(SEGMENT_1);
    assert_eq!(records.len(), 6, "segment-1 has 6 records");

    // file_hex is header_hex followed by every record_hex, byte for byte.
    let mut concatenated = header.clone();
    for record in &records {
        concatenated.extend_from_slice(record);
    }
    assert_eq!(concatenated, file);
    let vector = golden_vector(SEGMENT_1);
    assert_eq!(
        hex_encode(&file),
        vector.get("file_hex").and_then(Json::as_str).unwrap()
    );

    assert_eq!(scan_segment(&file), SEGMENT_1_SCAN);
    assert_eq!(
        classify_tail(&file).expect("segment-1 has a header"),
        r#"{"verdict":"clean"}"#
    );

    // Every record frame in the file verifies on its own.
    for (index, record) in records.iter().enumerate() {
        assert_eq!(
            verify_record(record),
            r#"{"ok":true}"#,
            "record {index} of segment-1"
        );
    }
}

/// `segment-epoch-only.json`: an idle epoch, `first_mseq = 88` and a close
/// record whose mseq is `durable_upto = 87`, byte for byte.
#[test]
fn golden_segment_epoch_only_scans_clean_and_is_byte_exact() {
    let file = golden_file(SEGMENT_EPOCH_ONLY);
    let records = golden_records(SEGMENT_EPOCH_ONLY);
    let header = golden_header(SEGMENT_EPOCH_ONLY);
    assert_eq!(records.len(), 1, "the idle epoch has one close record");

    let mut concatenated = header;
    concatenated.extend_from_slice(&records[0]);
    assert_eq!(concatenated, file);

    assert_eq!(scan_segment(&file), EPOCH_ONLY_SCAN);
    assert_eq!(
        classify_tail(&file).expect("the idle segment has a header"),
        r#"{"verdict":"clean"}"#
    );
    assert_eq!(verify_record(&records[0]), r#"{"ok":true}"#);
}

/// Dropping the last 10 bytes of `segment-1` leaves a partial epoch close with
/// no complete record after it: D19 truncates to the last complete record.
#[test]
fn a_torn_tail_is_truncated_to_the_last_complete_record() {
    let mut file = golden_file(SEGMENT_1);
    file.truncate(file.len() - 10);
    assert_eq!(file.len(), 367);

    assert_eq!(
        classify_tail(&file).expect("the header is intact"),
        r#"{"verdict":"truncate","keep":344,"dropped":23}"#
    );
    assert_eq!(
        scan_segment(&file),
        concat!(
            r#"{"header_ok":true,"corrupt":false,"first_mseq":42,"first_mutation_mseq":42,"#,
            r#""last_mutation_mseq":46,"epoch_close":null,"#,
            r#""torn_tail":{"keep_len":344,"dropped_bytes":23},"#,
            r#""chain_error":null,"header_error":null,"valid_len":344}"#
        )
    );

    // The torn bytes are not a complete record and verifyRecord says so
    // without deciding the tail question.
    let region = &file[40..];
    let last = &region[304..];
    let verified = parse_json(&verify_record(last));
    assert!(matches!(verified.get("ok"), Some(Json::Bool(false))));
    assert_eq!(string_member(&verified, "code"), "WAL_TRUNCATED");
    assert!(matches!(
        verified.get("tail_eligible"),
        Some(Json::Bool(true))
    ));
}

/// A CRC failure in the first record with a complete record after it is not a
/// tail tear: `WAL_CORRUPT`, and the failing offset is reported.
#[test]
fn a_non_tail_crc_failure_is_corrupt() {
    let mut file = golden_file(SEGMENT_1);
    // Byte 56 is the first byte of record 1's body (`op`), covered by the CRC.
    file[56] ^= 0xFF;

    assert_eq!(
        classify_tail(&file).expect("the header is intact"),
        r#"{"verdict":"corrupt","at":40}"#
    );
    assert_eq!(
        scan_segment(&file),
        concat!(
            r#"{"header_ok":true,"corrupt":true,"first_mseq":42,"#,
            r#""first_mutation_mseq":null,"last_mutation_mseq":0,"epoch_close":null,"#,
            r#""torn_tail":null,"chain_error":null,"header_error":null,"valid_len":40}"#
        )
    );
}

/// A header that does not verify is not record corruption: `header_ok:false`
/// sends the caller to the §10 step 1 missing-segment rule.
#[test]
fn a_bad_header_is_reported_separately_from_record_corruption() {
    let mut file = golden_file(SEGMENT_EPOCH_ONLY);
    file[0] ^= 0xFF;
    assert_eq!(
        scan_segment(&file),
        concat!(
            r#"{"header_ok":false,"corrupt":false,"first_mseq":0,"#,
            r#""first_mutation_mseq":null,"last_mutation_mseq":0,"epoch_close":null,"#,
            r#""torn_tail":null,"chain_error":null,"header_error":{"code":"WAL_HEADER_INVALID","#,
            r#""detail":"WAL segment magic is not XLWAL1"},"valid_len":0}"#
        )
    );

    let empty = scan_segment(&[]);
    assert_eq!(
        empty,
        concat!(
            r#"{"header_ok":false,"corrupt":false,"first_mseq":0,"#,
            r#""first_mutation_mseq":null,"last_mutation_mseq":0,"epoch_close":null,"#,
            r#""torn_tail":null,"chain_error":null,"header_error":{"code":"WAL_TRUNCATED","#,
            r#""detail":"truncated WAL data: need 40 bytes, have 0"},"valid_len":0}"#
        )
    );
    assert!(matches!(
        classify_tail(&[]),
        Err(WalError::Truncated { need: 40, have: 0 })
    ));
}

/// Both golden vectors decode through `records` and `decode_record`: the same
/// count, order and body members as the vector's `records[]`, the §3 `len` field
/// from the frame bytes, and `crc_ok:true`. `decode_record` on each
/// `record_hex` produces the identical object, so the whole-segment and
/// one-record entry points cannot disagree.
#[test]
fn golden_vectors_decode_through_records_and_decode_record() {
    for name in [SEGMENT_1, SEGMENT_EPOCH_ONLY] {
        let file = golden_file(name);
        let vector = golden_vector(name);
        let expected = vector
            .get("records")
            .and_then(Json::as_array)
            .unwrap_or_else(|| panic!("{name} has no records array"));

        let decoded = records(&file).unwrap_or_else(|error| panic!("{name}: {error}"));
        let decoded = parse_json(&decoded);
        let actual = decoded
            .as_array()
            .unwrap_or_else(|| panic!("{name}: records output is not an array"));
        assert_eq!(actual.len(), expected.len(), "{name}: record count");

        for (index, (actual, expected)) in actual.iter().zip(expected).enumerate() {
            let kind = string_member(expected, "kind");
            assert_eq!(
                actual.get("kind").and_then(Json::as_str),
                Some(kind),
                "{name}: record {index} kind"
            );
            assert_eq!(
                actual.get("crc_ok"),
                Some(&Json::Bool(true)),
                "{name}: record {index} crc_ok"
            );

            let frame = hex_decode(string_member(expected, "record_hex"));
            let len = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]) as u64;
            assert_eq!(
                actual.get("len").and_then(Json::as_u64),
                Some(len),
                "{name}: record {index} len"
            );

            // Every member of the golden `fields` object (mseq, op, mode,
            // mflags, append_from, path, data_len, data_hex, or wall_ms and
            // durable_upto) must have the same value in the decoded record.
            let fields = expected
                .get("fields")
                .and_then(Json::as_object)
                .unwrap_or_else(|| panic!("{name}: record {index} has no fields object"));
            for (member, value) in fields {
                assert_eq!(
                    actual.get(member),
                    Some(value),
                    "{name}: record {index} member {member:?}"
                );
            }

            let single = decode_record(&frame)
                .unwrap_or_else(|error| panic!("{name}: record {index}: {error}"));
            assert_eq!(
                parse_json(&single),
                actual.clone(),
                "{name}: record {index} decode_record"
            );
        }
    }
}

/// The bytes are individually valid, but record 3 skips mseq 43: a §3 order
/// violation is chain corruption, not a tear.
#[test]
fn a_record_order_violation_is_a_chain_error() {
    let records = golden_records(SEGMENT_1);
    let mut file = golden_header(SEGMENT_1);
    file.extend_from_slice(&records[0]);
    file.extend_from_slice(&records[2]);

    assert_eq!(file.len(), 160);
    assert_eq!(
        scan_segment(&file),
        concat!(
            r#"{"header_ok":true,"corrupt":true,"first_mseq":42,"first_mutation_mseq":42,"#,
            r#""last_mutation_mseq":44,"epoch_close":null,"torn_tail":null,"#,
            r#""chain_error":{"code":"WAL_CORRUPT","detail":"WAL mseq 44 does not continue 43"},"#,
            r#""header_error":null,"valid_len":160}"#
        )
    );
}
