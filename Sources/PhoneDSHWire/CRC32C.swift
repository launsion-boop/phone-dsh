// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHWire: CRC32C (Castagnoli).
//
// PLAN §2.2/§2.3 and spec/v1/README.md: CRC32C uses the Castagnoli
// polynomial 0x1EDC6F41, reflected input and output, with init and xorout
// 0xFFFFFFFF. It covers frame payloads only where a record says so: WAL record
// CRC32C is computed over `mseq ‖ body` and the segment-header CRC32C over the
// first 36 header bytes.

import Foundation

/// CRC-32C (Castagnoli), table-driven and reflected, as fixed by
/// `spec/v1/README.md`.
public enum CRC32C {
    /// Reflected Castagnoli polynomial used by the 256-entry lookup table.
    public static let polynomial: UInt32 = 0x82F6_3B78

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (value >> 1) ^ polynomial : value >> 1
        }
        return value
    }

    /// Returns the CRC-32C of `bytes` with init and xorout `0xFFFFFFFF`.
    public static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Continues a CRC-32C computation from a previous raw CRC value.
    ///
    /// `update` expects the value returned by `checksum` and applies the
    /// complement again before/after the update so callers can concatenate
    /// independent byte ranges (for example `mseq` then the mutation body).
    public static func update(_ crc: UInt32, with bytes: [UInt8]) -> UInt32 {
        var value = crc ^ 0xFFFF_FFFF
        for byte in bytes {
            value = (value >> 8) ^ table[Int((value ^ UInt32(byte)) & 0xFF)]
        }
        return value ^ 0xFFFF_FFFF
    }
}
