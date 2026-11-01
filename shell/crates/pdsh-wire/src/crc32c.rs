// SPDX-License-Identifier: MIT
//! CRC32C (Castagnoli): reflected polynomial `0x82F63B78`, init and xorout
//! `0xFFFFFFFF` (`spec/v1/README.md`).
//!
//! The channel itself does not prefix frames with a CRC; the WAL (D7, D19) uses
//! the same function for its records and its segment header, so the known answer
//! is pinned here once.

/// Reflected Castagnoli polynomial.
const POLYNOMIAL: u32 = 0x82F6_3B78;

/// The 256-entry lookup table, built at compile time.
const TABLE: [u32; 256] = build_table();

const fn build_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut index = 0;
    while index < 256 {
        let mut value = index as u32;
        let mut bit = 0;
        while bit < 8 {
            value = if value & 1 == 1 {
                (value >> 1) ^ POLYNOMIAL
            } else {
                value >> 1
            };
            bit += 1;
        }
        table[index] = value;
        index += 1;
    }
    table
}

/// Returns the CRC-32C of `bytes`.
///
/// The known answer is `crc32c(b"123456789") == 0xE3069283`.
pub fn crc32c(bytes: &[u8]) -> u32 {
    let mut state: u32 = 0xFFFF_FFFF;
    for &byte in bytes {
        let index = ((state ^ u32::from(byte)) & 0xFF) as usize;
        state = (state >> 8) ^ TABLE[index];
    }
    state ^ 0xFFFF_FFFF
}

#[cfg(test)]
mod tests {
    use super::crc32c;

    #[test]
    fn known_answer() {
        assert_eq!(crc32c(b"123456789"), 0xE306_9283);
    }

    #[test]
    fn empty_input_is_zero() {
        assert_eq!(crc32c(b""), 0);
    }
}
