// SPDX-License-Identifier: MIT
//! Entry-point tests for the WAL JNI bridge: `planRecovery`, `parseManifest`,
//! `emitManifest`, `verifyRecord`, `records`, `decodeRecord` and
//! `appendedReplay`.
//!
//! The golden scan output is fed to `planRecovery` unchanged (plus the name the
//! Kotlin layer reads from the directory), which is the round trip the `:core`
//! log package performs.

mod common;

use common::{golden_file, golden_header, golden_records, parse_json, string_member};
use pdsh_jni::wal::{
    appended_replay, classify_tail, decode_record, emit_manifest, error_code, error_message,
    parse_manifest, plan_recovery, records, scan_segment, verify_record, BridgeError,
    CODE_WAL_BAD_SEGMENT_NAME, CODE_WAL_CORRUPT, CODE_WAL_INPUT_INVALID, CODE_WAL_MANIFEST_INVALID,
};
use pdsh_wal::json::Json;
use pdsh_wal::WalError;

const SEGMENT_NAME: &str = "wal/00000001.000000.xlwal";

const MANIFEST: &str = concat!(
    r#"{"format":1,"boot_id":"00112233445566778899aabbccddeeff","#,
    r#""materialized_upto_mseq":46,"last_mseq":46,"last_durable_epoch":1,"#,
    r#""segments":[{"file":"wal/00000001.000000.xlwal","epoch":1,"#,
    r#""first_mseq":42,"last_mseq":46}]}"#
);

const MANIFEST_CANONICAL: &str = concat!(
    r#"{"boot_id":"00112233445566778899aabbccddeeff","format":1,"#,
    r#""last_durable_epoch":1,"last_mseq":46,"materialized_upto_mseq":46,"#,
    r#""segments":[{"epoch":1,"file":"wal/00000001.000000.xlwal","first_mseq":42,"#,
    r#""last_mseq":46}]}"#
);

/// `scanSegment`'s output is exactly the `wal_dir[]` entry `planRecovery`
/// consumes once the caller adds the directory name.
fn named_fact(name: &str, segment: &[u8]) -> String {
    let scan = scan_segment(segment);
    assert!(scan.starts_with('{'), "scanSegment output is an object");
    format!(r#"{{"name":"{name}",{}"#, &scan[1..])
}

fn plan_input(facts: &str, manifest: &str, marker: bool) -> String {
    format!(r#"{{"wal_dir":[{facts}],"manifest":{manifest},"reconcile_marker":{marker}}}"#)
}

#[test]
fn no_manifest_and_no_wal_is_a_new_workspace() {
    let plan = plan_recovery(&plan_input("", "null", false)).expect("new workspace plans");
    assert_eq!(
        plan,
        concat!(
            r#"{"replay_segments":[],"truncate":[],"drop_missing":[],"adopt":[],"stale":[],"#,
            r#""rebuild_manifest":true,"full_reconcile":false,"#,
            r#""clear_reconcile_marker":false,"manifest_tail_disagreement":false,"#,
            r#""effective_tail":0,"next_mseq":1,"next_epoch":1,"fail":null}"#
        )
    );
}

#[test]
fn a_reconcile_marker_on_a_new_workspace_requires_the_staged_reconcile() {
    let plan = plan_recovery(&plan_input("", "null", true)).expect("marker plans");
    assert_eq!(
        plan,
        concat!(
            r#"{"replay_segments":[],"truncate":[],"drop_missing":[],"adopt":[],"stale":[],"#,
            r#""rebuild_manifest":true,"full_reconcile":true,"#,
            r#""clear_reconcile_marker":true,"manifest_tail_disagreement":false,"#,
            r#""effective_tail":0,"next_mseq":1,"next_epoch":1,"fail":null}"#
        )
    );
}

#[test]
fn golden_segment_1_plans_a_clean_replay_against_its_manifest() {
    let file = golden_file("segment-1.json");
    let facts = named_fact(SEGMENT_NAME, &file);
    let plan = plan_recovery(&plan_input(&facts, MANIFEST, false)).expect("plan");
    assert_eq!(
        plan,
        concat!(
            r#"{"replay_segments":["wal/00000001.000000.xlwal"],"truncate":[],"#,
            r#""drop_missing":[],"adopt":[],"stale":[],"rebuild_manifest":false,"#,
            r#""full_reconcile":false,"clear_reconcile_marker":false,"#,
            r#""manifest_tail_disagreement":false,"effective_tail":46,"#,
            r#""next_mseq":47,"next_epoch":2,"fail":null}"#
        )
    );
}

#[test]
fn a_missing_manifest_with_a_truncated_history_is_a_corrupt_plan() {
    let file = golden_file("segment-1.json");
    let facts = named_fact(SEGMENT_NAME, &file);
    let plan = plan_recovery(&plan_input(&facts, "null", false)).expect("planning succeeds");
    assert_eq!(
        plan,
        concat!(
            r#"{"replay_segments":[],"truncate":[],"drop_missing":[],"adopt":[],"stale":[],"#,
            r#""rebuild_manifest":false,"full_reconcile":false,"#,
            r#""clear_reconcile_marker":false,"manifest_tail_disagreement":false,"#,
            r#""effective_tail":0,"next_mseq":1,"next_epoch":1,"fail":{"code":"WAL_CORRUPT","#,
            r#""detail":"manifest.json is missing and the earliest segment starts at mseq 42 "#,
            r#"instead of 1; a truncation must have happened and the copy cannot be rebuilt "#,
            r#"from the WAL"}}"#
        )
    );
}

#[test]
fn mseq_exhaustion_is_a_coded_plan_failure() {
    let facts = concat!(
        r#"{"name":"wal/00000001.000000.xlwal","header_ok":true,"corrupt":false,"#,
        r#""first_mseq":1,"first_mutation_mseq":1,"#,
        r#""last_mutation_mseq":18446744073709551615,"epoch_close":null}"#
    );
    let plan = plan_recovery(&plan_input(facts, "null", false)).expect("planning succeeds");
    assert_eq!(
        plan,
        concat!(
            r#"{"replay_segments":[],"truncate":[],"drop_missing":[],"adopt":[],"stale":[],"#,
            r#""rebuild_manifest":false,"full_reconcile":false,"#,
            r#""clear_reconcile_marker":false,"manifest_tail_disagreement":false,"#,
            r#""effective_tail":0,"next_mseq":1,"next_epoch":1,"fail":{"#,
            r#""code":"WAL_MSEQ_EXHAUSTED","#,
            r#""detail":"WAL mseq reached the u64 maximum"}}"#
        )
    );
}

#[test]
fn a_torn_tail_is_planned_for_truncation_and_replay() {
    let mut file = golden_file("segment-1.json");
    file.truncate(file.len() - 10);
    let facts = named_fact(SEGMENT_NAME, &file);
    let plan = plan_recovery(&plan_input(&facts, MANIFEST, false)).expect("plan");
    assert_eq!(
        plan,
        concat!(
            r#"{"replay_segments":["wal/00000001.000000.xlwal"],"truncate":[{"name":"#,
            r#""wal/00000001.000000.xlwal","keep_len":344,"dropped_bytes":23}],"#,
            r#""drop_missing":[],"adopt":[],"stale":[],"rebuild_manifest":false,"#,
            r#""full_reconcile":false,"clear_reconcile_marker":false,"#,
            r#""manifest_tail_disagreement":false,"effective_tail":46,"#,
            r#""next_mseq":47,"next_epoch":2,"fail":null}"#
        )
    );
}

#[test]
fn unknown_members_are_ignored_in_the_plan_input() {
    let file = golden_file("segment-1.json");
    let scan = scan_segment(&file);
    let facts = format!(
        r#"{{"name":"{SEGMENT_NAME}","future":{{"a":[1,2,3]}},{}"#,
        &scan[1..]
    );
    let manifest = MANIFEST.replacen('{', r#"{"comment":"ignored","#, 1);
    let plan = plan_recovery(&plan_input(&facts, &manifest, false)).expect("unknown members");
    assert_eq!(
        plan,
        plan_recovery(&plan_input(
            &named_fact(SEGMENT_NAME, &file),
            MANIFEST,
            false
        ))
        .expect("plain plan")
    );
}

#[test]
fn plan_input_errors_are_coded() {
    let cases = [
        ("not json", "plan input is not JSON"),
        (r#"{"manifest":null}"#, "no wal_dir"),
        (
            r#"{"wal_dir":{},"manifest":null}"#,
            "wal_dir is not an array",
        ),
        (
            r#"{"wal_dir":[{"name":"wal/00000001.000000.xlwal"}],"manifest":null}"#,
            "missing fact members",
        ),
        (
            r#"{"wal_dir":[],"manifest":null,"reconcile_marker":1}"#,
            "non-boolean marker",
        ),
    ];
    for (input, label) in cases {
        let error = plan_recovery(input).expect_err(label);
        assert_eq!(error.code(), CODE_WAL_INPUT_INVALID, "{label}");
        assert!(matches!(error, BridgeError::Input(_)), "{label}");
    }

    let bad_name = r#"{"wal_dir":[{"name":"nope","header_ok":true,"corrupt":false,"first_mseq":1,"last_mutation_mseq":0}],"manifest":null}"#;
    let error = plan_recovery(bad_name).expect_err("bad name");
    assert_eq!(error.code(), CODE_WAL_BAD_SEGMENT_NAME);
    assert!(matches!(
        error,
        BridgeError::Wal(WalError::BadSegmentName(_))
    ));
}

#[test]
fn an_embedded_invalid_manifest_is_reported_not_silently_dropped() {
    let invalid = r#"{"boot_id":"00112233445566778899aabbccddeeff","segments":[]}"#;
    let input = plan_input("", invalid, false);
    let error = plan_recovery(&input).expect_err("schema-invalid manifest");
    assert_eq!(error.code(), CODE_WAL_MANIFEST_INVALID);
    assert!(matches!(
        error,
        BridgeError::Wal(WalError::ManifestInvalid(_))
    ));

    let impossible = r#"{"format":1,"boot_id":"00112233445566778899aabbccddeeff","materialized_upto_mseq":47,"last_mseq":46,"last_durable_epoch":1,"segments":[]}"#;
    let input = plan_input("", impossible, false);
    let error = plan_recovery(&input).expect_err("impossible manifest");
    assert_eq!(error.code(), CODE_WAL_CORRUPT);
    assert!(matches!(error, BridgeError::Wal(WalError::Corrupt(_))));
}

#[test]
fn parse_manifest_returns_the_canonical_object_and_ignores_unknown_members() {
    let parsed = parse_manifest(MANIFEST_CANONICAL.as_bytes()).expect("canonical manifest");
    assert_eq!(parsed, MANIFEST_CANONICAL);

    let non_canonical = concat!(
        r#"{"comment":"ignored","segments":[{"future":true,"last_mseq":46,"first_mseq":42,"#,
        r#""file":"wal/00000001.000000.xlwal","epoch":1}],"last_durable_epoch":1,"#,
        r#""format":1,"last_mseq":46,"boot_id":"00112233445566778899aabbccddeeff","#,
        r#""materialized_upto_mseq":46,"unknown":{"a":[1,2,3]}}"#
    );
    assert_eq!(
        parse_manifest(non_canonical.as_bytes()).expect("unknown members are ignored"),
        MANIFEST_CANONICAL
    );
}

#[test]
fn parse_manifest_errors_are_coded() {
    let missing =
        parse_manifest(br#"{"boot_id":"00112233445566778899aabbccddeeff","segments":[]}"#)
            .expect_err("missing format");
    assert!(matches!(missing, WalError::ManifestInvalid(_)));
    assert_eq!(error_code(&missing), CODE_WAL_MANIFEST_INVALID);

    let impossible = parse_manifest(
        br#"{"format":1,"boot_id":"00112233445566778899aabbccddeeff","materialized_upto_mseq":47,"last_mseq":46,"last_durable_epoch":1,"segments":[]}"#,
    )
    .expect_err("watermark above last_mseq");
    assert!(matches!(impossible, WalError::Corrupt(_)));
    assert_eq!(error_code(&impossible), CODE_WAL_CORRUPT);
    assert_eq!(
        error_message(&impossible),
        concat!(
            "WAL_CORRUPT: manifest materialized_upto_mseq 47 ",
            "is above last_mseq 46"
        )
    );

    let not_json = parse_manifest(b"not json").expect_err("not JSON");
    assert!(matches!(not_json, WalError::ManifestInvalid(_)));

    let not_utf8 = parse_manifest(&[0xff, 0xfe]).expect_err("not UTF-8");
    assert!(matches!(not_utf8, WalError::ManifestInvalid(_)));

    let epoch_mismatch = parse_manifest(
        br#"{"format":1,"boot_id":"00112233445566778899aabbccddeeff","materialized_upto_mseq":46,"last_mseq":46,"last_durable_epoch":1,"segments":[{"file":"wal/00000002.000000.xlwal","epoch":1,"first_mseq":42,"last_mseq":46}]}"#,
    )
    .expect_err("file name and epoch disagree");
    assert!(matches!(epoch_mismatch, WalError::Corrupt(_)));
}

#[test]
fn emit_manifest_writes_the_canonical_bytes_and_round_trips() {
    let emitted = emit_manifest(MANIFEST).expect("canonical bytes");
    assert_eq!(emitted, MANIFEST_CANONICAL.as_bytes());
    assert!(!emitted.ends_with(b"\n"), "manifest.json has no newline");

    let reparsed = parse_manifest(&emitted).expect("emitted bytes parse");
    assert_eq!(reparsed, MANIFEST_CANONICAL);
    assert_eq!(
        emit_manifest(&reparsed).expect("round trip"),
        emitted.as_slice()
    );
}

#[test]
fn emit_manifest_errors_are_coded() {
    let error = emit_manifest("not json").expect_err("not JSON");
    assert!(matches!(error, WalError::ManifestInvalid(_)));

    let missing = emit_manifest(r#"{"format":1,"segments":[]}"#).expect_err("missing members");
    assert!(matches!(missing, WalError::ManifestInvalid(_)));

    let impossible = emit_manifest(
        r#"{"format":1,"boot_id":"00112233445566778899aabbccddeeff","materialized_upto_mseq":47,"last_mseq":46,"last_durable_epoch":1,"segments":[]}"#,
    )
    .expect_err("impossible manifest");
    assert!(matches!(impossible, WalError::Corrupt(_)));
}

#[test]
fn verify_record_reports_crc_mismatch_without_deciding_the_tail() {
    let records = golden_records("segment-1.json");
    let mut record = records[0].clone();
    let last = record.len() - 1;
    record[last] ^= 0xFF;

    let output = parse_json(&verify_record(&record));
    assert!(matches!(output.get("ok"), Some(Json::Bool(false))));
    assert_eq!(string_member(&output, "code"), "WAL_CORRUPT");
    assert!(matches!(
        output.get("tail_eligible"),
        Some(Json::Bool(true))
    ));
    assert!(
        string_member(&output, "detail").contains("record CRC32C mismatch"),
        "{output:?}"
    );
}

#[test]
fn verify_record_rejects_short_and_trailing_inputs() {
    assert_eq!(
        verify_record(&[]),
        concat!(
            r#"{"ok":false,"code":"WAL_TRUNCATED","#,
            r#""detail":"record prefix is incomplete: need 8 bytes, have 0","#,
            r#""tail_eligible":true}"#
        )
    );

    let mut record = golden_records("segment-1.json")[0].clone();
    let end = record.len();
    record.push(0);
    assert_eq!(
        verify_record(&record),
        format!(
            concat!(
                r#"{{"ok":false,"code":"WAL_INPUT_INVALID","#,
                r#""detail":"the record ends at byte {end} but {total} bytes were passed","#,
                r#""tail_eligible":false}}"#
            ),
            end = end,
            total = record.len()
        )
    );
}

#[test]
fn verify_record_rejects_a_crc_valid_record_with_a_bad_operation() {
    // op 9 is not a VFS operation; the body is CRC-valid, so it is malformed
    // rather than a torn tail.
    let mut body = Vec::new();
    body.push(9); // op
    body.extend_from_slice(&0u32.to_be_bytes()); // mode
    body.push(0); // mflags
    body.extend_from_slice(&0u64.to_be_bytes()); // append_from
    body.extend_from_slice(&1u16.to_be_bytes()); // path_len
    body.push(b'/');
    body.extend_from_slice(&0u32.to_be_bytes()); // data_len

    let mut payload = 1u64.to_be_bytes().to_vec();
    payload.extend_from_slice(&body);
    let mut frame = Vec::new();
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(&pdsh_wire::crc32c(&payload).to_be_bytes());
    frame.extend_from_slice(&payload);

    assert_eq!(
        verify_record(&frame),
        concat!(
            r#"{"ok":false,"code":"WAL_CORRUPT","#,
            r#""detail":"malformed WAL record: unknown VFS op 9","#,
            r#""tail_eligible":false}"#
        )
    );
}

#[test]
fn classify_tail_needs_a_header() {
    let error = classify_tail(&[0u8; 39]).expect_err("shorter than a header");
    assert!(matches!(error, WalError::Truncated { need: 40, have: 39 }));
}

/// A header-only segment is legal (`wal.md` §1) and holds no record.
#[test]
fn records_decodes_a_header_only_segment_to_an_empty_array() {
    let header = golden_header("segment-1.json");
    assert_eq!(records(&header).expect("header only"), "[]");
}

/// A missing header, a bad header and a non-tail record failure are errors, not
/// a partial array: replaying a prefix with an unexplained hole is forbidden.
#[test]
fn records_rejects_a_bad_header_and_a_non_tail_failure() {
    let no_header = records(&[]).expect_err("an empty file has no header");
    assert_eq!(no_header.code(), "WAL_TRUNCATED");
    assert!(matches!(
        no_header,
        BridgeError::Wal(WalError::Truncated { need: 40, have: 0 })
    ));

    let mut bad_magic = golden_header("segment-1.json");
    bad_magic[0] ^= 0xFF;
    let bad_magic = records(&bad_magic).expect_err("magic is wrong");
    assert_eq!(bad_magic.code(), "WAL_HEADER_INVALID");
    assert!(matches!(bad_magic, BridgeError::Wal(WalError::BadMagic)));

    let mut bad_record = golden_file("segment-1.json");
    // Byte 56 is the first body byte of record 1, covered by its CRC.
    bad_record[56] ^= 0xFF;
    let bad_record = records(&bad_record).expect_err("non-tail CRC failure");
    assert_eq!(bad_record.code(), CODE_WAL_CORRUPT);
    assert!(matches!(bad_record, BridgeError::Wal(WalError::Corrupt(_))));
}

/// A D19 torn tail is not an error and is not a record: `records` returns the
/// verified prefix and `classify_tail` owns the truncation verdict.
#[test]
fn records_returns_the_verified_prefix_of_a_torn_tail() {
    let mut file = golden_file("segment-1.json");
    file.truncate(file.len() - 10);

    let decoded = parse_json(&records(&file).expect("a torn tail is not an error"));
    let array = decoded.as_array().expect("records output is an array");
    assert_eq!(array.len(), 5, "the torn epoch close is not a record");
    assert!(array
        .iter()
        .all(|record| { matches!(record.get("kind").and_then(Json::as_str), Some("mutation")) }));
    assert_eq!(
        array
            .last()
            .and_then(|record| record.get("mseq"))
            .and_then(Json::as_u64),
        Some(46)
    );
}

/// Individually valid records with an mseq hole are a §3 violation, not a tear.
#[test]
fn records_rejects_an_mseq_hole() {
    let frames = golden_records("segment-1.json");
    let mut file = golden_header("segment-1.json");
    file.extend_from_slice(&frames[0]);
    file.extend_from_slice(&frames[2]);

    let error = records(&file).expect_err("mseq 43 is missing");
    assert_eq!(error.code(), CODE_WAL_CORRUPT);
    assert!(matches!(
        error,
        BridgeError::Wal(WalError::MseqNotConsecutive {
            expected: 43,
            found: 44
        })
    ));
}

/// One mutation and the epoch close, decoded exactly: `len` is the §3 field,
/// and the body members are the §3.1/§3 names.
#[test]
fn decode_record_decodes_a_mutation_and_the_epoch_close_exactly() {
    let frames = golden_records("segment-1.json");
    assert_eq!(
        decode_record(&frames[0]).expect("write record"),
        concat!(
            r#"{"mseq":42,"len":58,"crc_ok":true,"kind":"mutation","op":1,"mode":420,"#,
            r#""mflags":1,"append_from":0,"path":"/dsh/workspace/notes.txt","#,
            r#""data_len":6,"data_hex":"68656c6c6f0a"}"#
        )
    );
    assert_eq!(
        decode_record(&frames[5]).expect("epoch close"),
        concat!(
            r#"{"mseq":46,"len":25,"crc_ok":true,"kind":"epoch_close","op":255,"#,
            r#""wall_ms":1792800000123,"durable_upto":46}"#
        )
    );
}

/// Short, trailing and CRC-failing inputs are coded errors; only a complete,
/// CRC-verified record produces content.
#[test]
fn decode_record_rejects_short_trailing_and_crc_failing_inputs() {
    let short = decode_record(&[]).expect_err("no record");
    assert_eq!(short.code(), "WAL_TRUNCATED");
    assert!(matches!(
        short,
        BridgeError::Wal(WalError::Truncated { need: 8, have: 0 })
    ));

    let mut frame = golden_records("segment-1.json")[0].clone();
    frame.push(0);
    let trailing = decode_record(&frame).expect_err("trailing byte");
    assert_eq!(trailing.code(), CODE_WAL_INPUT_INVALID);
    assert!(matches!(trailing, BridgeError::Input(_)));

    let mut crc = golden_records("segment-1.json")[0].clone();
    let last = crc.len() - 1;
    crc[last] ^= 0xFF;
    let crc = decode_record(&crc).expect_err("CRC mismatch");
    assert_eq!(crc.code(), CODE_WAL_CORRUPT);
}

/// The three D9 verdicts of `wal.md` §6.2.
#[test]
fn appended_replay_reports_the_three_d9_verdicts() {
    let data = b"world\n";
    assert_eq!(
        appended_replay(6, 6, data, Some(b"world\n")),
        r#"{"verdict":"applied"}"#
    );
    assert_eq!(
        appended_replay(12, 6, data, Some(b"world\n")),
        r#"{"verdict":"skip"}"#
    );
    assert_eq!(
        appended_replay(12, 6, data, Some(b"other\n")),
        r#"{"verdict":"resync"}"#
    );
    assert_eq!(
        appended_replay(12, 6, data, None),
        r#"{"verdict":"resync"}"#
    );
}

/// The boundaries: empty data still follows §6.2, an absent/short base and an
/// `append_from + len` overflow are base mismatches rather than panics.
#[test]
fn appended_replay_handles_the_boundaries_as_base_mismatches() {
    assert_eq!(
        appended_replay(5, 5, b"", Some(b"")),
        r#"{"verdict":"applied"}"#
    );
    assert_eq!(
        appended_replay(6, 5, b"", Some(b"")),
        r#"{"verdict":"skip"}"#
    );
    assert_eq!(
        appended_replay(0, u64::MAX, b"x", Some(b"")),
        r#"{"verdict":"resync"}"#
    );
    assert_eq!(
        appended_replay(10, 6, b"world\n", Some(b"wor")),
        r#"{"verdict":"resync"}"#
    );
    assert_eq!(
        appended_replay(3, 6, b"world\n", Some(b"world\n")),
        r#"{"verdict":"resync"}"#
    );
}
