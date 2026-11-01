// SPDX-License-Identifier: MIT
//! WAL conformance: `spec/v1/golden/wal/*.json`, byte for byte.
//!
//! Each vector carries `header` (fields plus `header_hex`), `records[]` (each
//! with `kind`, `fields`, `crc32c` and `record_hex`) and `file_hex` =
//! `header_hex` followed by every `record_hex`. The test parses the bytes,
//! verifies every CRC, checks the parsed header/record fields against the JSON
//! members, and re-emits the file **byte for byte**.
//!
//! The expected file count and the expected records per file are fixed on
//! purpose: a vector that silently disappears, or a parser that silently skips
//! records, fails the test.

mod common;

use std::fs;
use std::path::Path;

use common::{
    close, crc32c, golden_wal_dir, hex_decode, hex_encode, mkdir, name, segment_file, write, BOOT_ID,
};
use pdsh_wal::json::Json;
use pdsh_wal::{
    classify_tail, scan_segment, Record, RecordChain, SegmentHeader, SegmentName, TailVerdict,
    HEADER_BYTES,
};

/// `spec/v1/README.md`: the Castagnoli known answer.
#[test]
fn crc32c_known_answer() {
    assert_eq!(crc32c(b"123456789"), 0xE306_9283);
}

/// The directory holds exactly the two vectors the checker knows, so a vector
/// that disappears (or an unexpected file) fails loudly.
#[test]
fn golden_wal_directory_holds_exactly_two_vectors() {
    let dir = golden_wal_dir();
    let mut names: Vec<String> = fs::read_dir(&dir)
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
        vec![
            "segment-1.json".to_string(),
            "segment-epoch-only.json".to_string()
        ],
        "expected exactly 2 golden WAL vectors in {}",
        dir.display()
    );
}

/// `segment-1.json`: 5 mutations then the epoch close, byte for byte.
#[test]
fn golden_segment_1_is_byte_exact() {
    check_vector(&golden_wal_dir().join("segment-1.json"), 6);
}

/// `segment-epoch-only.json`: an idle epoch, `first_mseq = 88` and a close
/// record whose mseq is `durable_upto = 87`, byte for byte.
#[test]
fn golden_segment_epoch_only_is_byte_exact() {
    check_vector(&golden_wal_dir().join("segment-epoch-only.json"), 1);
}

fn check_vector(path: &Path, expected_records: usize) {
    let text = fs::read_to_string(path).expect("golden vector is readable");
    let vector = pdsh_wal::json::parse(&text).expect("golden vector is JSON");
    let header_json = vector.get("header").expect("header member");
    let records_json = vector
        .get("records")
        .and_then(Json::as_array)
        .expect("records member");
    assert_eq!(
        records_json.len(),
        expected_records,
        "{}: expected {expected_records} records",
        path.display()
    );

    let file_bytes = hex_decode(
        vector
            .get("file_hex")
            .and_then(Json::as_str)
            .expect("file_hex member"),
    );
    let header_bytes = hex_decode(
        header_json
            .get("header_hex")
            .and_then(Json::as_str)
            .expect("header_hex member"),
    );
    assert_eq!(header_bytes.len(), HEADER_BYTES);

    // header: parse, compare every field with the JSON member, re-emit.
    let header = SegmentHeader::parse(&file_bytes, &crc32c).expect("header parses");
    assert_eq!(u64::from(header.format), uint(header_json, "format"));
    assert_eq!(u64::from(header.reserved), uint(header_json, "reserved"));
    assert_eq!(header.first_mseq, uint(header_json, "first_mseq"));
    assert_eq!(
        hex_encode(&header.boot_id),
        header_json
            .get("boot_id_hex")
            .and_then(Json::as_str)
            .expect("boot_id_hex member")
    );
    assert_eq!(u64::from(header.header_crc32c), uint(header_json, "header_crc32c"));
    assert_eq!(header.emit().as_slice(), header_bytes.as_slice());

    // file_hex is header_hex followed by every record_hex.
    let mut concatenated = header_bytes.clone();
    for record_json in records_json {
        concatenated.extend(hex_decode(
            record_json
                .get("record_hex")
                .and_then(Json::as_str)
                .expect("record_hex member"),
        ));
    }
    assert_eq!(concatenated, file_bytes);
    assert_eq!(
        hex_encode(&file_bytes),
        vector.get("file_hex").and_then(Json::as_str).unwrap()
    );

    // The D19 tail verdict and the whole-file scan agree with the JSON.
    let region = &file_bytes[HEADER_BYTES..];
    assert_eq!(classify_tail(region, &crc32c), TailVerdict::Clean);
    let scan = scan_segment(&file_bytes, &crc32c);
    assert!(scan.header_ok());
    assert_eq!(scan.records.len(), expected_records);
    assert_eq!(scan.valid_len, file_bytes.len());
    assert_eq!(scan.verdict, TailVerdict::Clean);
    assert!(scan.chain_error.is_none(), "{}: record order", path.display());

    // Walk the record frames at their exact offsets.
    let mut offset = HEADER_BYTES;
    for record_json in records_json {
        let record_bytes = hex_decode(
            record_json
                .get("record_hex")
                .and_then(Json::as_str)
                .expect("record_hex member"),
        );
        let parsed = Record::parse(&file_bytes[offset..], &crc32c).expect("record parses");
        assert_eq!(
            parsed.byte_len,
            record_bytes.len(),
            "{}: record at {offset} has the wrong length",
            path.display()
        );
        assert_eq!(
            &file_bytes[offset..offset + parsed.byte_len],
            record_bytes.as_slice()
        );
        assert_eq!(parsed.record.emit(&crc32c).expect("record re-emits"), record_bytes);

        // The stored CRC member is the record's crc32c field.
        let stored_crc = u32::try_from(uint(record_json, "crc32c")).expect("crc32c fits u32");
        let crc_field = u32::from_be_bytes([
            record_bytes[4],
            record_bytes[5],
            record_bytes[6],
            record_bytes[7],
        ]);
        assert_eq!(crc_field, stored_crc);
        let (mseq, body) = match &parsed.record {
            Record::Mutation(mutation) => (
                mutation.mseq,
                mutation.body.emit().expect("mutation body re-emits"),
            ),
            Record::EpochClose(close) => (close.mseq(), close.body().to_vec()),
        };
        let mut payload = mseq.to_be_bytes().to_vec();
        payload.extend_from_slice(&body);
        assert_eq!(crc32c(&payload), stored_crc);
        assert_eq!(
            u32::try_from(payload.len()).expect("payload len fits u32"),
            u32::from_be_bytes([record_bytes[0], record_bytes[1], record_bytes[2], record_bytes[3]])
        );

        // The semantic fields agree with the parsed record and its kind.
        let fields = record_json.get("fields").expect("fields member");
        let kind = record_json
            .get("kind")
            .and_then(Json::as_str)
            .expect("kind member");
        match (&parsed.record, kind) {
            (Record::Mutation(mutation), "mutation") => {
                assert_eq!(mutation.mseq, uint(fields, "mseq"));
                assert_eq!(u64::from(mutation.body.op), uint(fields, "op"));
                assert_eq!(u64::from(mutation.body.mode), uint(fields, "mode"));
                assert_eq!(u64::from(mutation.body.mflags), uint(fields, "mflags"));
                assert_eq!(mutation.body.append_from, uint(fields, "append_from"));
                assert_eq!(
                    mutation.body.path,
                    fields.get("path").and_then(Json::as_str).unwrap()
                );
                let data = hex_decode(
                    fields
                        .get("data_hex")
                        .and_then(Json::as_str)
                        .expect("data_hex member"),
                );
                assert_eq!(u64::try_from(data.len()).unwrap(), uint(fields, "data_len"));
                assert_eq!(mutation.body.data, data);
                assert_eq!(parsed.record.wire_mseq(), mutation.mseq);
                assert!(parsed.record.advances_materialized());
                assert!(parsed.record.epoch_close().is_none());
            }
            (Record::EpochClose(close), "epoch_close") => {
                // D7: the record's mseq field is durable_upto.
                assert_eq!(close.durable_upto, uint(fields, "durable_upto"));
                assert_eq!(close.mseq(), close.durable_upto);
                assert_eq!(close.wall_ms, uint(fields, "wall_ms"));
                assert_eq!(u64::from(pdsh_wal::OP_EPOCH_CLOSE), uint(fields, "op"));
                assert_eq!(uint(fields, "mseq"), close.durable_upto);
                assert_eq!(parsed.record.wire_mseq(), close.durable_upto);
                assert!(!parsed.record.advances_materialized());
                assert_eq!(parsed.record.mutation_mseq(), None);
            }
            _ => panic!("{}: kind {kind} disagrees with the parsed record", path.display()),
        }
        offset += parsed.byte_len;
    }
    assert_eq!(offset, file_bytes.len(), "record frames cover the file");

    // Re-emit the whole file: header then every record, byte for byte.
    let mut emitted = header.emit().to_vec();
    for record in &scan.records {
        emitted.extend(record.emit(&crc32c).expect("record re-emits"));
    }
    assert_eq!(emitted, file_bytes, "{}: re-emit differs", path.display());

    // The per-segment chain rule: consecutive mutations, close last.
    let mut chain = RecordChain::from_header(&header);
    for record in &scan.records {
        chain
            .push(record)
            .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    }
    let closes = usize::from(chain.epoch_close().is_some());
    assert_eq!(chain.mutations() + closes, expected_records);
    assert_eq!(
        chain.last_mutation_mseq(),
        scan.last_mutation_mseq(),
        "{}: chain tail",
        path.display()
    );
}

fn uint(json: &Json, member: &str) -> u64 {
    json.get(member)
        .and_then(Json::as_u64)
        .unwrap_or_else(|| panic!("missing integer member {member}"))
}

/// The hand-computed header of `wal.md` §2: `first_mseq = 1`, 16 zero boot-id
/// bytes, `header_crc32c = 0x0B0F9536`.
#[test]
fn spec_hand_computed_header_matches() {
    let header = SegmentHeader::new(1, [0u8; 16], &crc32c).expect("header");
    assert_eq!(header.header_crc32c, 0x0B0F_9536);
    assert_eq!(
        hex_encode(&header.emit()),
        "584c57414c310000000100000000000000000001000000000000000000000000000000000b0f9536"
    );
}

#[test]
fn segment_name_matches_the_golden_file_spelling() {
    let parsed = SegmentName::parse("wal/00000001.000000.xlwal").expect("name");
    assert_eq!(parsed, name(1, 0));
    assert_eq!(parsed.base_name(), "00000001.000000.xlwal");
    assert_eq!(parsed.file(), "wal/00000001.000000.xlwal");
    assert_eq!(parsed.to_string(), "wal/00000001.000000.xlwal");
}

#[test]
fn a_built_segment_scans_clean_and_round_trips() {
    let records = [
        write(7, "/dsh/workspace/a.txt", b"hello\n"),
        mkdir(8, "/dsh/workspace/dir"),
        close(1_792_800_000_000, 8),
    ];
    let bytes = segment_file(7, BOOT_ID, &records);
    let scan = scan_segment(&bytes, &crc32c);
    assert!(scan.header_ok());
    assert_eq!(scan.verdict, TailVerdict::Clean);
    assert_eq!(scan.records, records);
    assert_eq!(scan.valid_len, bytes.len());
    assert_eq!(scan.first_mutation_mseq(), Some(7));
    assert_eq!(scan.last_mutation_mseq(), 8);
    assert_eq!(scan.epoch_close(), Some(8));
}
