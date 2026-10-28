// SPDX-License-Identifier: MIT
// Minimal gzip reader used by the PhoneDSHLogTests overlay assertions
// (D21: the overlay packer emits one gzip member around the ustar bytes).

import Compression
import Foundation

enum GzipParser {
    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    /// Inflates one gzip member and verifies its CRC-32 and ISIZE trailer.
    static func decompress(_ archive: Data) throws -> Data {
        let bytes = [UInt8](archive)
        guard bytes.count >= 18,
              bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else {
            throw ParseError(description: "not a gzip member")
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else {
                throw ParseError(description: "truncated FEXTRA length")
            }
            let length = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + length
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset + 8 <= bytes.count else {
            throw ParseError(description: "truncated gzip payload")
        }
        let payload = Array(bytes[offset..<(bytes.count - 8)])
        let expectedCRC = readLittleEndian(bytes, at: bytes.count - 8)
        let expectedSize = readLittleEndian(bytes, at: bytes.count - 4)
        let inflated = try inflate(payload)
        guard crc32(inflated) == expectedCRC else {
            throw ParseError(description: "gzip CRC-32 mismatch")
        }
        guard UInt32(truncatingIfNeeded: inflated.count) == expectedSize else {
            throw ParseError(description: "gzip ISIZE mismatch")
        }
        return inflated
    }

    private static func inflate(_ payload: [UInt8]) throws -> Data {
        guard payload.isEmpty == false else {
            throw ParseError(description: "empty DEFLATE payload")
        }
        var capacity = max(1024, payload.count * 4)
        while capacity <= 512 * 1024 * 1024 {
            var output = [UInt8](repeating: 0, count: capacity)
            let count = compression_decode_buffer(&output, capacity,
                                                  payload, payload.count,
                                                  nil, COMPRESSION_ZLIB)
            if count > 0 {
                if count < capacity { return Data(output.prefix(count)) }
                // Exactly filled: the result may be truncated, retry larger.
                capacity *= 2
                continue
            }
            if capacity >= 512 * 1024 * 1024 { break }
            capacity *= 2
        }
        throw ParseError(description: "DEFLATE failed")
    }

    private static func readLittleEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var entry = UInt32(index)
        for _ in 0..<8 {
            entry = (entry & 1) == 1
                ? (entry >> 1) ^ 0xEDB8_8320
                : entry >> 1
        }
        return entry
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in data {
            value = crcTable[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8)
        }
        return value ^ 0xffff_ffff
    }
}
