// SPDX-License-Identifier: MIT
//! Header, record-frame, mutation-body and mseq-chain canaries at the byte level.
//!
//! The golden vectors cover the real files; these tests pin the boundaries a
//! vector cannot (every layout error the format can express, and the type-level
//! difference between a mutation and the epoch close).

mod common;

use common::{chmod, close, crc32c, mkdir, name, record_bytes, remove, segment_file, write, BOOT_ID};
use pdsh_wal::epoch::EPOCH_CLOSE_BODY_BYTES;
use pdsh_wal::{
    MutationBody, Record, RecordChain, RecordParseError, SegmentHeader, SegmentName, WalError,
    BODY_HEADER_BYTES, HEADER_BYTES, MAGIC, MFLAG_APPENDED, MFLAG_ENTRY_CHANGED,
};

fn raw_record(mseq: u64, body: &[u8]) -> Vec<u8> {
    let mut payload = mseq.to_be_bytes().to_vec();
    payload.extend_from_slice(body);
    let mut out = (payload.len() as u32).to_be_bytes().to_vec();
    out.extend_from_slice(&crc32c(&payload).to_be_bytes());
    out.extend_from_slice(&payload);
    out
}

fn body(op: u8, mode: u32, mflags: u8, append_from: u64, path: &[u8], data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.push(op);
    out.extend_from_slice(&mode.to_be_bytes());
    out.push(mflags);
    out.extend_from_slice(&append_from.to_be_bytes());
    out.extend_from_slice(&(path.len() as u16).to_be_bytes());
    out.extend_from_slice(path);
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(data);
    out
}

#[test]
fn header_round_trips_with_a_non_zero_boot_id() {
    let header = SegmentHeader::new(42, BOOT_ID, &crc32c).expect("header");
    let bytes = header.emit();
    assert_eq!(bytes.len(), HEADER_BYTES);
    assert_eq!(&bytes[0..8], &MAGIC);
    assert_eq!(u16::from_be_bytes([bytes[8], bytes[9]]), 1);
    assert_eq!(u16::from_be_bytes([bytes[10], bytes[11]]), 0);
    assert_eq!(
        u64::from_be_bytes(bytes[12..20].try_into().expect("first_mseq")),
        42
    );
    assert_eq!(&bytes[20..36], &BOOT_ID);
    assert_eq!(SegmentHeader::parse(&bytes, &crc32c).expect("parse"), header);
    assert_eq!(
        header.boot_id_hex(),
        "00112233445566778899aabbccddeeff"
    );
}

#[test]
fn header_layout_errors_are_values() {
    let good = SegmentHeader::new(1, BOOT_ID, &crc32c).expect("header").emit();

    let mut short = good.to_vec();
    short.pop();
    assert!(matches!(
        SegmentHeader::parse(&short, &crc32c),
        Err(WalError::Truncated { need: 40, have: 39 })
    ));

    let mut magic = good;
    magic[0] = b'X';
    magic[1] = b'Y';
    assert!(matches!(SegmentHeader::parse(&magic, &crc32c), Err(WalError::BadMagic)));

    let mut format = good;
    format[9] = 2;
    assert!(matches!(
        SegmentHeader::parse(&format, &crc32c),
        Err(WalError::UnsupportedFormat(2))
    ));

    let mut reserved = good;
    reserved[11] = 1;
    assert!(matches!(
        SegmentHeader::parse(&reserved, &crc32c),
        Err(WalError::NonZeroReserved(1))
    ));

    let mut first = good;
    first[12..20].copy_from_slice(&0u64.to_be_bytes());
    assert!(matches!(
        SegmentHeader::parse(&first, &crc32c),
        Err(WalError::InvalidFirstMseq(0))
    ));

    let mut crc = good;
    crc[36] ^= 0xFF;
    assert!(matches!(
        SegmentHeader::parse(&crc, &crc32c),
        Err(WalError::HeaderCrcMismatch { .. })
    ));

    assert!(matches!(
        SegmentHeader::new(0, BOOT_ID, &crc32c),
        Err(WalError::InvalidFirstMseq(0))
    ));
}

#[test]
fn every_mutation_op_round_trips_through_its_frame() {
    let records = [
        write(1, "/dsh/workspace/notes.txt", b"hello\n"),
        common::append(2, "/dsh/workspace/notes.txt", 6, b"world\n"),
        mkdir(3, "/dsh/workspace/sub"),
        remove(4, "/dsh/workspace/old.txt"),
        chmod(5, "/dsh/workspace/notes.txt", 0o600),
        close(1_792_800_000_123, 5),
    ];
    for record in &records {
        let bytes = record_bytes(record);
        let parsed = Record::parse(&bytes, &crc32c).expect("record parses");
        assert_eq!(&parsed.record, record);
        assert_eq!(parsed.byte_len, bytes.len());
        assert_eq!(parsed.record.emit(&crc32c).expect("re-emit"), bytes);
    }
    // mflags: bit 0 entryChanged, bit 1 appended.
    let Record::Mutation(mutation) = &records[0] else {
        panic!("a write is a mutation");
    };
    assert_eq!(mutation.body.mflags & MFLAG_ENTRY_CHANGED, 0);
    let Record::Mutation(appended) = &records[1] else {
        panic!("an append is a mutation");
    };
    assert!(appended.body.is_appended());
    assert_eq!(appended.body.mflags & MFLAG_APPENDED, MFLAG_APPENDED);
    assert_eq!(appended.body.append_from, 6);
}

#[test]
fn a_record_frame_is_len_crc_mseq_body() {
    let path = "/dsh/workspace/a.txt";
    let data = b"0123456789";
    let record = write(9, path, data);
    let Record::Mutation(mutation) = &record else {
        panic!("a write is a mutation");
    };
    let emitted = record_bytes(&record);
    let body = mutation.body.emit().expect("body");
    assert_eq!(
        u32::from_be_bytes(emitted[0..4].try_into().unwrap()) as usize,
        8 + body.len(),
        "len covers mseq and body"
    );
    let mut payload = 9u64.to_be_bytes().to_vec();
    payload.extend_from_slice(&body);
    assert_eq!(
        u32::from_be_bytes(emitted[4..8].try_into().unwrap()),
        crc32c(&payload),
        "crc covers mseq and body only"
    );
    assert_eq!(u64::from_be_bytes(emitted[8..16].try_into().unwrap()), 9);
    assert_eq!(&emitted[16..], body.as_slice());
    assert_eq!(body.len(), BODY_HEADER_BYTES + path.len() + 4 + data.len());
}

#[test]
fn record_layout_errors_are_values() {
    let good = record_bytes(&write(1, "/dsh/workspace/a.txt", b"x"));

    assert!(matches!(
        Record::parse(&good[..7], &crc32c),
        Err(RecordParseError::ShortHeader { need: 8, have: 7 })
    ));

    let mut bad_len = good.clone();
    bad_len[0..4].copy_from_slice(&4u32.to_be_bytes());
    assert!(matches!(
        Record::parse(&bad_len, &crc32c),
        Err(RecordParseError::BadLength(4))
    ));

    assert!(matches!(
        Record::parse(&good[..good.len() - 1], &crc32c),
        Err(RecordParseError::ShortRecord { .. })
    ));

    let mut bad_crc = good.clone();
    let last = bad_crc.len() - 1;
    bad_crc[last] ^= 0xFF;
    assert!(matches!(
        Record::parse(&bad_crc, &crc32c),
        Err(RecordParseError::CrcMismatch { .. })
    ));

    // A complete, CRC-verified record whose body is wrong.
    let empty_body = raw_record(1, &[]);
    assert!(matches!(
        Record::parse(&empty_body, &crc32c),
        Err(RecordParseError::Malformed(_))
    ));
    assert!(!Record::parse(&empty_body, &crc32c)
        .unwrap_err()
        .is_tail_eligible());

    let zero_mseq = raw_record(0, &body(1, 0o644, 0, 0, b"/dsh/workspace/a", b""));
    assert!(matches!(
        Record::parse(&zero_mseq, &crc32c),
        Err(RecordParseError::Malformed(WalError::ZeroMseq))
    ));

    let unknown_op = raw_record(1, &body(9, 0, 0, 0, b"/dsh/workspace/a", b""));
    assert!(matches!(
        Record::parse(&unknown_op, &crc32c),
        Err(RecordParseError::Malformed(_))
    ));

    let not_utf8 = raw_record(1, &body(1, 0o644, 0, 0, &[0xFF, 0xFE], b""));
    assert!(matches!(
        Record::parse(&not_utf8, &crc32c),
        Err(RecordParseError::Malformed(_))
    ));

    // data_len names more bytes than the body holds.
    let mut short_data = body(1, 0o644, 0, 0, b"/dsh/workspace/a", b"abc");
    let data_len_at = BODY_HEADER_BYTES + "/dsh/workspace/a".len();
    short_data[data_len_at..data_len_at + 4].copy_from_slice(&10u32.to_be_bytes());
    let short_data = raw_record(1, &short_data);
    assert!(matches!(
        Record::parse(&short_data, &crc32c),
        Err(RecordParseError::Malformed(_))
    ));

    // Trailing bytes after the declared data.
    let mut trailing = body(1, 0o644, 0, 0, b"/dsh/workspace/a", b"abc");
    trailing.push(0x00);
    let trailing = raw_record(1, &trailing);
    assert!(matches!(
        Record::parse(&trailing, &crc32c),
        Err(RecordParseError::Malformed(_))
    ));
}

#[test]
fn the_epoch_close_is_a_different_type_with_its_own_rules() {
    let record = close(1_792_800_000_123, 46);
    let emitted = record_bytes(&record);
    let Record::EpochClose(epoch_close) = &record else {
        panic!("the close record is not a mutation");
    };
    assert_eq!(epoch_close.body().len(), EPOCH_CLOSE_BODY_BYTES);
    assert_eq!(epoch_close.body()[0], pdsh_wal::OP_EPOCH_CLOSE);
    assert_eq!(epoch_close.mseq(), epoch_close.durable_upto);
    assert_eq!(
        u64::from_be_bytes(emitted[8..16].try_into().unwrap()),
        epoch_close.durable_upto,
        "the record mseq field is durable_upto"
    );
    assert!(!record.advances_materialized());
    assert_eq!(record.mutation_mseq(), None);
    assert_eq!(record.epoch_close(), Some(epoch_close));

    // A close body of the wrong size, and a mseq that is not durable_upto, are
    // malformed even with a valid CRC.
    let short = raw_record(0, &[pdsh_wal::OP_EPOCH_CLOSE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    assert!(matches!(
        Record::parse(&short, &crc32c),
        Err(RecordParseError::Malformed(_))
    ));
    let mismatch = raw_record(9, &epoch_close.body());
    assert!(matches!(
        Record::parse(&mismatch, &crc32c),
        Err(RecordParseError::Malformed(_))
    ));
    // An idle epoch: first_mseq 88, the close carries 87.
    let idle = segment_file(88, BOOT_ID, &[close(1_792_800_060_000, 87)]);
    let scan = pdsh_wal::scan_segment(&idle, &crc32c);
    assert_eq!(scan.last_mutation_mseq(), 0);
    let mut chain = RecordChain::new(88);
    for record in &scan.records {
        chain.push(record).expect("an idle close does not continue the mutation chain");
    }
    assert_eq!(chain.epoch_close().map(|close| close.durable_upto), Some(87));
}

#[test]
fn mutation_body_validation_matches_channel_section_three() {
    let bad_mode = MutationBody::new(1, 0o10000, 0, 0, "/dsh/workspace/a", Vec::new());
    assert!(bad_mode.validate().is_err());

    let reserved_flag = MutationBody::new(1, 0o644, 0x04, 0, "/dsh/workspace/a", Vec::new());
    assert!(reserved_flag.validate().is_err());

    let complete_with_offset = MutationBody::new(1, 0o644, 0, 9, "/dsh/workspace/a", Vec::new());
    assert!(complete_with_offset.validate().is_err());

    let mkdir_with_data = MutationBody::new(2, 0o755, 0, 0, "/dsh/workspace/a", vec![1]);
    assert!(mkdir_with_data.validate().is_err());

    let remove_with_mode = MutationBody::new(3, 0o644, 0, 0, "/dsh/workspace/a", Vec::new());
    assert!(remove_with_mode.validate().is_err());

    let chmod_with_flags = MutationBody::new(4, 0o600, MFLAG_ENTRY_CHANGED, 0, "/dsh/workspace/a", Vec::new());
    assert!(chmod_with_flags.validate().is_err());

    let empty_path = MutationBody::new(1, 0o644, 0, 0, "", Vec::new());
    assert!(empty_path.validate().is_err());

    // A body round-trips through parse(emit).
    let body = MutationBody::new(
        pdsh_wal::OP_WRITE,
        0o644,
        MFLAG_APPENDED,
        12,
        "/dsh/workspace/a",
        b"suffix".to_vec(),
    );
    let bytes = body.emit().expect("emit");
    assert_eq!(MutationBody::parse(&bytes).expect("parse"), body);
    let scan = pdsh_wal::scan_segment(&segment_file(1, BOOT_ID, &[write(1, "/dsh/workspace/a", b"x")]), &crc32c);
    assert_eq!(scan.last_mutation_mseq(), 1);
}

#[test]
fn the_record_chain_enforces_strict_consecutive_mseqs() {
    let mut chain = RecordChain::new(3);
    assert_eq!(chain.first_mseq(), 3);
    assert_eq!(chain.next_mutation_mseq(), 3);
    chain.push(&write(3, "/dsh/workspace/a", b"a")).expect("3");
    chain.push(&mkdir(4, "/dsh/workspace/d")).expect("4");
    assert_eq!(chain.mutations(), 2);
    assert_eq!(chain.last_mutation_mseq(), 4);
    assert!(matches!(
        chain.push(&write(6, "/dsh/workspace/b", b"b")),
        Err(WalError::MseqNotConsecutive { expected: 5, found: 6 })
    ));
    chain.push(&write(5, "/dsh/workspace/b", b"b")).expect("5");
    chain.push(&close(1, 5)).expect("close");
    assert!(matches!(
        chain.push(&write(6, "/dsh/workspace/c", b"c")),
        Err(WalError::RecordAfterEpochClose)
    ));
    assert!(matches!(
        chain.push(&close(2, 6)),
        Err(WalError::DuplicateEpochClose)
    ));

    let mut zero = RecordChain::new(1);
    let zero_mseq = Record::Mutation(pdsh_wal::Mutation {
        mseq: 0,
        body: MutationBody::new(1, 0o644, 0, 0, "/dsh/workspace/a", Vec::new()),
    });
    assert!(matches!(zero.push(&zero_mseq), Err(WalError::ZeroMseq)));
}

#[test]
fn segment_names_are_zero_padded_and_range_checked() {
    assert!(SegmentName::parse("wal/00000001.000000.xlwal").is_ok());
    assert!(SegmentName::parse("00000002.000003.xlwal").is_ok());
    for bad in [
        "wal/1.0.xlwal",
        "wal/00000001.00000.xlwal",
        "wal/00000001.0000001.xlwal",
        "wal/100000000.000000.xlwal",
        "wal/00000000.000000.xlwal",
        "wal/00000001.000000.xlwax",
        "wal/00000001-000000.xlwal",
        "wal/0000000a.000000.xlwal",
        "wal/00000001.000000.xlwal.bak",
    ] {
        assert!(
            SegmentName::parse(bad).is_err(),
            "{bad} must not parse as a segment name"
        );
    }
    assert!(SegmentName::new(0, 0).is_err());
    assert!(SegmentName::new(1, 1_000_000).is_err());
    let mut names = vec![name(2, 0), name(1, 5), name(1, 0)];
    names.sort();
    assert_eq!(names, vec![name(1, 0), name(1, 5), name(2, 0)]);
}

#[test]
fn record_parse_errors_carry_a_display_and_a_wal_error() {
    let error = RecordParseError::BadLength(3);
    assert!(error.to_string().contains('3'));
    assert_eq!(error.clone().into_wal_error(), WalError::BadLength(3));
    let error = Record::parse(&[0u8; 2], &crc32c).unwrap_err();
    assert_eq!(error.clone().into_wal_error(), WalError::Truncated { need: 8, have: 2 });
    assert!(error.to_string().contains("incomplete"));
}
