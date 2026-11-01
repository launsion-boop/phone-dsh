// SPDX-License-Identifier: MIT
//! D19 tail-tear exhaustive cases (`wal.md` §10).
//!
//! The rule under test: an incomplete or mismatching `len`/`crc32c` with no
//! complete record after it is a **torn tail** — truncate to the last complete
//! record and log, never an error. A failure that is not at the tail, or a
//! CRC-verified but malformed record, is `WAL_CORRUPT`.

mod common;

use common::{close, crc32c, mkdir, name, record_bytes, segment_file, write, BOOT_ID};
use pdsh_wal::{
    classify_tail, scan_segment, Record, RecordParseError, SegmentHeader, TailVerdict,
    HEADER_BYTES, RECORD_PREFIX_BYTES,
};

fn three_mutations() -> Vec<u8> {
    segment_file(
        1,
        BOOT_ID,
        &[
            write(1, "/dsh/workspace/a.txt", b"alpha\n"),
            write(2, "/dsh/workspace/b.txt", b"bravo\n"),
            write(3, "/dsh/workspace/c.txt", b"charlie\n"),
        ],
    )
}

#[test]
fn empty_region_is_clean() {
    assert_eq!(classify_tail(&[], &crc32c), TailVerdict::Clean);
}

#[test]
fn complete_records_are_clean() {
    let bytes = three_mutations();
    let region = &bytes[HEADER_BYTES..];
    assert_eq!(classify_tail(region, &crc32c), TailVerdict::Clean);
}

#[test]
fn half_a_length_prefix_is_truncated() {
    let mut bytes = three_mutations();
    let keep = bytes.len() - HEADER_BYTES;
    bytes.extend_from_slice(&[0x00, 0x00, 0x00, 0x3a]);
    assert_eq!(
        classify_tail(&bytes[HEADER_BYTES..], &crc32c),
        TailVerdict::Truncate { keep, dropped: 4 }
    );
}

#[test]
fn half_a_crc_prefix_is_truncated() {
    let mut bytes = three_mutations();
    let keep = bytes.len() - HEADER_BYTES;
    bytes.extend_from_slice(&[0x00, 0x00, 0x00, 0x3a, 0x64, 0xba]);
    assert_eq!(
        classify_tail(&bytes[HEADER_BYTES..], &crc32c),
        TailVerdict::Truncate { keep, dropped: 6 }
    );
}

#[test]
fn one_byte_after_a_complete_record_is_truncated() {
    let mut bytes = three_mutations();
    let keep = bytes.len() - HEADER_BYTES;
    bytes.push(0x00);
    assert_eq!(
        classify_tail(&bytes[HEADER_BYTES..], &crc32c),
        TailVerdict::Truncate { keep, dropped: 1 }
    );
}

#[test]
fn tail_garbage_is_truncated() {
    let mut bytes = three_mutations();
    let keep = bytes.len() - HEADER_BYTES;
    bytes.extend_from_slice(&[0xAA; 32]);
    assert_eq!(
        classify_tail(&bytes[HEADER_BYTES..], &crc32c),
        TailVerdict::Truncate { keep, dropped: 32 }
    );
}

#[test]
fn bad_crc_in_the_last_record_is_truncated() {
    let mut bytes = three_mutations();
    let records = [
        write(1, "/dsh/workspace/a.txt", b"alpha\n"),
        write(2, "/dsh/workspace/b.txt", b"bravo\n"),
        write(3, "/dsh/workspace/c.txt", b"charlie\n"),
    ];
    let last_len = record_bytes(&records[2]).len();
    let keep = bytes.len() - HEADER_BYTES - last_len;
    // Flip the final data byte: `len` stays intact, the CRC no longer matches.
    let last = bytes.len() - 1;
    bytes[last] ^= 0xFF;
    assert_eq!(
        classify_tail(&bytes[HEADER_BYTES..], &crc32c),
        TailVerdict::Truncate {
            keep,
            dropped: last_len
        }
    );
}

#[test]
fn bad_crc_in_the_middle_is_corrupt() {
    let mut bytes = three_mutations();
    let records = [
        write(1, "/dsh/workspace/a.txt", b"alpha\n"),
        write(2, "/dsh/workspace/b.txt", b"bravo\n"),
        write(3, "/dsh/workspace/c.txt", b"charlie\n"),
    ];
    let first_len = record_bytes(&records[0]).len();
    let at = first_len;
    // A body byte of the second record, after `len|crc32c|mseq`.
    bytes[HEADER_BYTES + at + RECORD_PREFIX_BYTES + 9] ^= 0xFF;
    assert_eq!(
        classify_tail(&bytes[HEADER_BYTES..], &crc32c),
        TailVerdict::Corrupt { at }
    );
}

#[test]
fn a_corrupted_length_in_the_middle_is_corrupt() {
    let mut bytes = three_mutations();
    let records = [
        write(1, "/dsh/workspace/a.txt", b"alpha\n"),
        write(2, "/dsh/workspace/b.txt", b"bravo\n"),
        write(3, "/dsh/workspace/c.txt", b"charlie\n"),
    ];
    let first_len = record_bytes(&records[0]).len();
    let at = first_len;
    let len_at = HEADER_BYTES + at;
    bytes[len_at..len_at + 4].copy_from_slice(&0u32.to_be_bytes());
    // The byte scan finds the third record after the corrupted `len`.
    assert_eq!(
        classify_tail(&bytes[HEADER_BYTES..], &crc32c),
        TailVerdict::Corrupt { at }
    );
}

#[test]
fn a_corrupted_length_at_the_tail_is_truncated() {
    let mut bytes = three_mutations();
    let records = [
        write(1, "/dsh/workspace/a.txt", b"alpha\n"),
        write(2, "/dsh/workspace/b.txt", b"bravo\n"),
        write(3, "/dsh/workspace/c.txt", b"charlie\n"),
    ];
    let keep = bytes.len() - HEADER_BYTES - record_bytes(&records[2]).len();
    let len_at = HEADER_BYTES + keep;
    let dropped = bytes.len() - len_at;
    bytes[len_at..len_at + 4].copy_from_slice(&0u32.to_be_bytes());
    assert_eq!(
        classify_tail(&bytes[HEADER_BYTES..], &crc32c),
        TailVerdict::Truncate { keep, dropped }
    );
}

#[test]
fn a_malformed_body_with_a_valid_crc_is_corrupt_even_at_the_tail() {
    // op 9 is not a mutation op; the CRC is computed over the bad body, so the
    // bytes were written completely and are simply wrong.
    let body = [0x09u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    let mut payload = 1u64.to_be_bytes().to_vec();
    payload.extend_from_slice(&body);
    let mut bytes = SegmentHeader::new(1, BOOT_ID, &crc32c).expect("header").emit().to_vec();
    bytes.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    bytes.extend_from_slice(&crc32c(&payload).to_be_bytes());
    bytes.extend_from_slice(&payload);
    assert_eq!(
        classify_tail(&bytes[HEADER_BYTES..], &crc32c),
        TailVerdict::Corrupt { at: 0 }
    );
}

#[test]
fn epoch_close_is_not_a_torn_tail() {
    let bytes = segment_file(88, BOOT_ID, &[close(1_792_800_060_000, 87)]);
    let scan = scan_segment(&bytes, &crc32c);
    assert_eq!(scan.verdict, TailVerdict::Clean);
    assert!(scan.chain_error.is_none());
    assert_eq!(scan.records.len(), 1);
    assert_eq!(scan.epoch_close(), Some(87));
    // The idle epoch: first_mseq 88, the close carries 87.
    assert_eq!(scan.header.unwrap().first_mseq, 88);
    assert_eq!(scan.last_mutation_mseq(), 0);
    assert_eq!(scan.first_mutation_mseq(), None);
}

#[test]
fn scan_reports_the_truncation_with_the_header_offset() {
    let mut bytes = three_mutations();
    let keep_len = bytes.len();
    bytes.extend_from_slice(&[0xAA; 5]);
    let scan = scan_segment(&bytes, &crc32c);
    assert_eq!(
        scan.verdict,
        TailVerdict::Truncate {
            keep: keep_len - HEADER_BYTES,
            dropped: 5
        }
    );
    assert_eq!(scan.valid_len, keep_len);
    assert_eq!(scan.record_region_len, keep_len - HEADER_BYTES + 5);
    assert!(scan.chain_error.is_none());
    let truncation = scan.truncation(name(1, 0)).expect("truncation");
    assert_eq!(truncation.keep_len, keep_len);
    assert_eq!(truncation.offset(), keep_len);
    assert_eq!(truncation.dropped_bytes, 5);
}

#[test]
fn an_empty_file_has_no_header_and_drops_everything() {
    let scan = scan_segment(&[], &crc32c);
    assert!(!scan.header_ok());
    assert_eq!(scan.records.len(), 0);
    assert_eq!(scan.valid_len, 0);
    assert!(scan.header_error.is_some());
}

#[test]
fn a_short_header_is_unreadable_not_clean() {
    let bytes = segment_file(1, BOOT_ID, &[write(1, "/dsh/workspace/a.txt", b"x")]);
    let scan = scan_segment(&bytes[..HEADER_BYTES - 1], &crc32c);
    assert!(!scan.header_ok());
    assert_eq!(scan.valid_len, 0);
}

#[test]
fn a_corrupt_header_is_unreadable() {
    let mut bytes = segment_file(1, BOOT_ID, &[write(1, "/dsh/workspace/a.txt", b"x")]);
    bytes[12] ^= 0xFF;
    let scan = scan_segment(&bytes, &crc32c);
    assert!(!scan.header_ok());
    assert_eq!(scan.valid_len, 0);
    assert_eq!(scan.records.len(), 0);
}

#[test]
fn a_record_after_the_epoch_close_is_a_chain_error() {
    let records = [close(1_792_800_060_000, 3), mkdir(4, "/dsh/workspace/sub")];
    let bytes = segment_file(1, BOOT_ID, &records);
    let scan = scan_segment(&bytes, &crc32c);
    // The bytes are individually valid, so the tail verdict is clean; the order
    // rule is reported separately and makes the segment corrupt for recovery.
    assert_eq!(scan.verdict, TailVerdict::Clean);
    assert!(scan.chain_error.is_some());
    assert!(scan.is_corrupt());
    let facts = pdsh_wal::SegmentFacts::from_scan(name(1, 0), &scan);
    assert!(facts.corrupt);
    let mut chain = pdsh_wal::RecordChain::new(1);
    chain.push(&records[0]).unwrap();
    assert!(chain.push(&records[1]).is_err());
}

#[test]
fn record_parse_error_taxonomy_matches_d19() {
    // The failure kinds that may be a torn tail and the ones that never are.
    let short = Record::parse(&[0u8; 4], &crc32c).unwrap_err();
    assert!(matches!(short, RecordParseError::ShortHeader { .. }));
    assert!(short.is_tail_eligible());

    let mut bytes = three_mutations();
    let last = bytes.len() - 1;
    bytes[last] ^= 0xFF;
    let crc = Record::parse(&bytes[HEADER_BYTES + 1..], &crc32c).unwrap_err();
    assert!(crc.is_tail_eligible());
}

#[test]
fn a_torn_large_record_is_truncated() {
    // BUG-1's big-file shape: one legal record larger than the 8 MiB roll bound,
    // cut off inside its body by a process kill. There is no complete record
    // after it, so D19 must truncate, not report WAL_CORRUPT.
    let data: Vec<u8> = (0..9 * 1024 * 1024).map(|index| (index % 251) as u8).collect();
    let record = write(1, "/dsh/workspace/big.bin", &data);
    let mut bytes = segment_file(1, BOOT_ID, &[record]);
    let dropped = 5 * 1024 * 1024;
    bytes.truncate(bytes.len() - dropped);
    let region = &bytes[HEADER_BYTES..];
    assert_eq!(
        classify_tail(region, &crc32c),
        TailVerdict::Truncate { keep: 0, dropped: region.len() }
    );
}
