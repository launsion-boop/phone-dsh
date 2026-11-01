// SPDX-License-Identifier: MIT
//! WAL segment header (`wal.md` §2): 40 bytes, big-endian, CRC32C over bytes 0–35.
//!
//! ```text
//! 0  8  magic          "XLWAL1\0\0"
//! 8  2  format         u16 = 1
//! 10 2  reserved       u16 = 0
//! 12 8  first_mseq     u64 = next_mseq at segment creation
//! 20 16 boot_id        16 raw bytes (the HELLO boot identity without the hex form)
//! 36 4  header_crc32c  u32 CRC32C over bytes 0–35
//! ```
//!
//! A header is written once. Only the D19 torn-tail rule of §10 truncates, and
//! it truncates records, never the header (an unreadable header makes the file
//! unreadable, which §10 step 1 handles as a missing segment).

use crate::checksum::Checksum;
use crate::error::{WalError, WalResult};

/// Header size fixed by `wal.md` §2.
pub const HEADER_BYTES: usize = 40;
/// The 8 magic bytes of `wal.md` §2: `58 4c 57 41 4c 31 00 00`.
pub const MAGIC: [u8; 8] = *b"XLWAL1\0\0";
/// The only `format` value of proto 1.
pub const FORMAT: u16 = 1;
/// The 16 raw `boot_id` bytes.
pub const BOOT_ID_BYTES: usize = 16;
const CRC_OFFSET: usize = 36;

/// A parsed 40-byte WAL segment header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SegmentHeader {
    /// `format`, always 1 for proto 1.
    pub format: u16,
    /// `reserved`, always 0.
    pub reserved: u16,
    /// The mseq the first mutation of the segment will receive; at least 1.
    pub first_mseq: u64,
    /// The raw 16 boot-id bytes.
    pub boot_id: [u8; BOOT_ID_BYTES],
    /// The stored CRC32C over bytes 0–35.
    pub header_crc32c: u32,
}

impl SegmentHeader {
    /// Builds a format-1 header for `first_mseq` and `boot_id`, computing the
    /// CRC with `cks`.
    ///
    /// `first_mseq` must be at least 1: segment 0 of epoch 1 is created when
    /// `next_mseq` is 1, and a header is never written for mseq 0.
    pub fn new(first_mseq: u64, boot_id: [u8; BOOT_ID_BYTES], cks: &dyn Checksum) -> WalResult<Self> {
        if first_mseq < 1 {
            return Err(WalError::InvalidFirstMseq(first_mseq));
        }
        let mut header = SegmentHeader {
            format: FORMAT,
            reserved: 0,
            first_mseq,
            boot_id,
            header_crc32c: 0,
        };
        header.header_crc32c = cks.crc32c(&header.prefix());
        Ok(header)
    }

    /// The 36 bytes the header CRC covers.
    pub fn prefix(&self) -> [u8; CRC_OFFSET] {
        let mut bytes = [0u8; CRC_OFFSET];
        bytes[0..8].copy_from_slice(&MAGIC);
        bytes[8..10].copy_from_slice(&self.format.to_be_bytes());
        bytes[10..12].copy_from_slice(&self.reserved.to_be_bytes());
        bytes[12..20].copy_from_slice(&self.first_mseq.to_be_bytes());
        bytes[20..36].copy_from_slice(&self.boot_id);
        bytes
    }

    /// The complete 40 header bytes, including the stored `header_crc32c`.
    pub fn emit(&self) -> [u8; HEADER_BYTES] {
        let mut bytes = [0u8; HEADER_BYTES];
        bytes[0..CRC_OFFSET].copy_from_slice(&self.prefix());
        bytes[CRC_OFFSET..].copy_from_slice(&self.header_crc32c.to_be_bytes());
        bytes
    }

    /// Parses and verifies the header at the start of `bytes` (`bytes` may be
    /// longer than one header; only the first 40 bytes are used).
    pub fn parse(bytes: &[u8], cks: &dyn Checksum) -> WalResult<Self> {
        if bytes.len() < HEADER_BYTES {
            return Err(WalError::Truncated {
                need: HEADER_BYTES,
                have: bytes.len(),
            });
        }
        if bytes[0..8] != MAGIC {
            return Err(WalError::BadMagic);
        }
        let format = u16::from_be_bytes([bytes[8], bytes[9]]);
        if format != FORMAT {
            return Err(WalError::UnsupportedFormat(format));
        }
        let reserved = u16::from_be_bytes([bytes[10], bytes[11]]);
        if reserved != 0 {
            return Err(WalError::NonZeroReserved(reserved));
        }
        let first_mseq = u64::from_be_bytes(
            bytes[12..20]
                .try_into()
                .map_err(|_| WalError::Truncated { need: 20, have: bytes.len() })?,
        );
        if first_mseq < 1 {
            return Err(WalError::InvalidFirstMseq(first_mseq));
        }
        let mut boot_id = [0u8; BOOT_ID_BYTES];
        boot_id.copy_from_slice(&bytes[20..36]);
        let stored = u32::from_be_bytes(
            bytes[CRC_OFFSET..HEADER_BYTES]
                .try_into()
                .map_err(|_| WalError::Truncated { need: HEADER_BYTES, have: bytes.len() })?,
        );
        let computed = cks.crc32c(&bytes[0..CRC_OFFSET]);
        if stored != computed {
            return Err(WalError::HeaderCrcMismatch { stored, computed });
        }
        Ok(SegmentHeader {
            format,
            reserved,
            first_mseq,
            boot_id,
            header_crc32c: stored,
        })
    }

    /// The `boot_id` as the 32 lowercase hex characters of D6.
    pub fn boot_id_hex(&self) -> String {
        let mut out = String::with_capacity(32);
        for byte in self.boot_id {
            out.push_str(&format!("{byte:02x}"));
        }
        out
    }
}
