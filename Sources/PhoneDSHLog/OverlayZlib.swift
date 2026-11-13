// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: raw-DEFLATE and CRC-32 primitives for
// the incremental boot overlay (wal.md §8, D21).
//
// The boot overlay is assembled from independent per-entry DEFLATE fragments.
// Each fragment is a complete raw-deflate stream ended with Z_SYNC_FLUSH, so
// it has no BFINAL block and can be concatenated with the next fragment: no
// back-reference ever crosses a fragment boundary. The final `03 00` block
// closes the concatenation. CRC-32 is CRC-32/ISO-HDLC (the gzip polynomial),
// taken from zlib and combined over fragments with crc32_combine.

import Foundation
import zlib

enum OverlayZlib {
    /// The system zlib version. A cache built by a different zlib is ignored:
    /// fragment bytes are only guaranteed to match a cold rebuild while the
    /// compressor is the same, and the overlay must stay deterministic for a
    /// given tree whether the fragment cache is cold or warm.
    static var version: String {
        let value = zlibVersion()
        return value.map { String(cString: $0) } ?? "unknown"
    }

    /// RFC 1952 header: magic, DEFLATE, no flags, mtime 0, no extra flags,
    /// OS = unknown (255).
    static let gzipHeader = Data([
        0x1f, 0x8b, 0x08, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0xff,
    ])

    /// The fixed final block of the concatenated stream: BFINAL=1, BTYPE=01
    /// (fixed Huffman), end-of-block. This is what deflate(Z_FINISH) emits for
    /// empty input; it is used literally so no fragment carries BFINAL.
    static let finalEmptyBlock = Data([0x03, 0x00])

    /// Compresses `chunks` as one fresh raw-deflate stream ended with
    /// Z_SYNC_FLUSH. Concatenating the results of several calls is a valid
    /// DEFLATE stream because none of them sets BFINAL.
    static func deflate(_ chunks: [Data]) throws -> Data {
        var stream = z_stream()
        let started = deflateInit2_(&stream,
                                    Z_BEST_SPEED,
                                    Z_DEFLATED,
                                    -15,
                                    8,
                                    Z_DEFAULT_STRATEGY,
                                    zlibVersion(),
                                    Int32(MemoryLayout<z_stream>.size))
        guard started == Z_OK else {
            throw LogError.materializationFailed("overlay DEFLATE could not start")
        }
        defer { _ = deflateEnd(&stream) }

        let capacity = 64 * 1024
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { output.deallocate() }
        var result = Data()

        for chunk in chunks where !chunk.isEmpty {
            try chunk.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var source = base
                var remaining = raw.count
                while remaining > 0 {
                    stream.next_in = UnsafeMutablePointer(mutating: source)
                    stream.avail_in = uInt(remaining)
                    stream.next_out = output
                    stream.avail_out = uInt(capacity)
                    let status = zlib.deflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK else {
                        throw LogError.materializationFailed("overlay DEFLATE failed")
                    }
                    let consumed = remaining - Int(stream.avail_in)
                    let produced = capacity - Int(stream.avail_out)
                    source = source.advanced(by: consumed)
                    remaining -= consumed
                    if produced > 0 {
                        result.append(output, count: produced)
                    }
                    if consumed == 0 && produced == 0 {
                        throw LogError.materializationFailed("overlay DEFLATE made no progress")
                    }
                }
            }
        }

        // Flush the stream to a byte boundary with an empty stored block. It
        // deliberately does not finish: the next fragment is a new stream.
        while true {
            stream.next_in = nil
            stream.avail_in = 0
            stream.next_out = output
            stream.avail_out = uInt(capacity)
            let status = zlib.deflate(&stream, Z_SYNC_FLUSH)
            guard status == Z_OK else {
                throw LogError.materializationFailed("overlay DEFLATE flush failed")
            }
            let produced = capacity - Int(stream.avail_out)
            if produced > 0 {
                result.append(output, count: produced)
            }
            if Int(stream.avail_out) > 0 {
                break
            }
            if produced == 0 {
                throw LogError.materializationFailed("overlay DEFLATE made no progress")
            }
        }
        return result
    }

    /// CRC-32 of the concatenation of `chunks`.
    static func crc32(_ chunks: [Data]) -> uLong {
        var value: uLong = 0
        for chunk in chunks {
            value = chunk.withUnsafeBytes { raw in
                zlib.crc32(value,
                           raw.bindMemory(to: UInt8.self).baseAddress,
                           uInt(raw.count))
            }
        }
        return value
    }

    static func crc32(_ data: Data) -> uLong {
        crc32([data])
    }

    /// CRC-32 of `crc1` followed by `length` bytes whose CRC is `crc2`.
    static func combine(_ crc1: uLong, _ crc2: uLong, length: Int) -> uLong {
        guard length > 0 else { return crc1 }
        return zlib.crc32_combine(crc1, crc2, length)
    }

    /// The RFC 1952 trailer: CRC-32 and ISIZE, both little-endian.
    static func gzipTrailer(crc: uLong, size: UInt64) -> Data {
        var trailer = Data()
        appendLittleEndian(UInt32(truncatingIfNeeded: crc), to: &trailer)
        appendLittleEndian(UInt32(truncatingIfNeeded: size), to: &trailer)
        return trailer
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
