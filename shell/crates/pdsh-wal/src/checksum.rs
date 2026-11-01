// SPDX-License-Identifier: MIT
//! Checksum injection (`wal.md` §2–§4, README §4).
//!
//! Every CRC32C in this crate is supplied by the caller. Production wires the
//! wire codec's Castagnoli implementation in; the conformance tests inject a
//! test-only one. The crate therefore has no checksum dependency and cannot
//! drift from the codec that actually writes the bytes.

/// A CRC32C (Castagnoli, reflected polynomial `0x82F63B78`, init and xorout
/// `0xFFFFFFFF`) provider.
///
/// The known answer fixed by `spec/v1/README.md` is
/// `crc32c(b"123456789") == 0xE3069283`.
pub trait Checksum {
    /// CRC32C of `bytes`.
    fn crc32c(&self, bytes: &[u8]) -> u32;
}

impl<F> Checksum for F
where
    F: Fn(&[u8]) -> u32,
{
    fn crc32c(&self, bytes: &[u8]) -> u32 {
        self(bytes)
    }
}
