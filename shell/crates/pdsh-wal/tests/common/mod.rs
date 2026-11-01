// SPDX-License-Identifier: MIT
//! Test-only helpers: a CRC32C and small hex codecs.
//!
//! The CRC32C below is **test-only**. Production wiring must inject the wire
//! codec's Castagnoli implementation through `pdsh_wal::Checksum`; this crate
//! deliberately owns no second CRC32C. The implementation is table-free so the
//! known answer (`crc32c(b"123456789") == 0xE3069283`) is easy to audit.

#![allow(dead_code)]

use std::path::PathBuf;

use pdsh_wal::{
    Manifest, ManifestSegment, MutationBody, Record, SegmentHeader, SegmentName, OP_CHMOD,
    OP_EPOCH_CLOSE, OP_MKDIR, OP_REMOVE, OP_WRITE,
};

/// Test-only CRC32C (Castagnoli, reflected polynomial `0x82F63B78`).
pub fn crc32c(bytes: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = if crc & 1 == 1 {
                (crc >> 1) ^ 0x82F6_3B78
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

/// The 16 raw `boot_id` bytes the golden vectors and these tests share.
pub const BOOT_ID: [u8; 16] = [
    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
];

/// A segment name.
pub fn name(epoch: u32, segment: u32) -> SegmentName {
    SegmentName::new(epoch, segment).expect("test segment name")
}

/// Lowercase hex of `bytes`.
pub fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// Bytes of a lowercase hex string.
pub fn hex_decode(text: &str) -> Vec<u8> {
    assert!(text.len() % 2 == 0, "hex text has an odd length");
    (0..text.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&text[index..index + 2], 16).expect("hex pair"))
        .collect()
}

/// The directory of the WAL conformance vectors.
pub fn golden_wal_dir() -> PathBuf {
    PathBuf::from(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../spec/v1/golden/wal"
    ))
}

/// A record's bytes.
pub fn record_bytes(record: &Record) -> Vec<u8> {
    record.emit(&crc32c).expect("test record emits")
}

/// A complete segment file: header then every record.
pub fn segment_file(first_mseq: u64, boot_id: [u8; 16], records: &[Record]) -> Vec<u8> {
    let header = SegmentHeader::new(first_mseq, boot_id, &crc32c).expect("test header");
    let mut bytes = header.emit().to_vec();
    for record in records {
        bytes.extend(record_bytes(record));
    }
    bytes
}

/// A complete write mutation record.
pub fn write(mseq: u64, path: &str, data: &[u8]) -> Record {
    Record::mutation(
        mseq,
        MutationBody::new(OP_WRITE, 0o644, 0, 0, path, data.to_vec()),
    )
    .expect("test write")
}

/// An appended write mutation record.
pub fn append(mseq: u64, path: &str, append_from: u64, data: &[u8]) -> Record {
    Record::mutation(
        mseq,
        MutationBody::new(OP_WRITE, 0o644, 0x02, append_from, path, data.to_vec()),
    )
    .expect("test append")
}

/// A mkdir mutation record.
pub fn mkdir(mseq: u64, path: &str) -> Record {
    Record::mutation(mseq, MutationBody::new(OP_MKDIR, 0o755, 0, 0, path, Vec::new()))
        .expect("test mkdir")
}

/// A remove mutation record.
pub fn remove(mseq: u64, path: &str) -> Record {
    Record::mutation(mseq, MutationBody::new(OP_REMOVE, 0, 0, 0, path, Vec::new()))
        .expect("test remove")
}

/// A chmod mutation record.
pub fn chmod(mseq: u64, path: &str, mode: u32) -> Record {
    Record::mutation(mseq, MutationBody::new(OP_CHMOD, mode, 0, 0, path, Vec::new()))
        .expect("test chmod")
}

/// The epoch-close record.
pub fn close(wall_ms: u64, durable_upto: u64) -> Record {
    Record::close(wall_ms, durable_upto)
}

/// The epoch-close op byte, for byte-level tests.
pub const EPOCH_CLOSE_OP: u8 = OP_EPOCH_CLOSE;

/// A manifest of the given segments, built from their manifest ranges.
pub fn manifest(
    boot_id: [u8; 16],
    last_mseq: u64,
    materialized_upto_mseq: u64,
    last_durable_epoch: u32,
    segments: &[(SegmentName, u64, u64)],
) -> Manifest {
    Manifest::new(
        boot_id,
        materialized_upto_mseq,
        last_mseq,
        last_durable_epoch,
        segments
            .iter()
            .map(|(name, first, last)| ManifestSegment::new(*name, *first, *last))
            .collect(),
    )
}
