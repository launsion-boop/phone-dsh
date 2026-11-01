// SPDX-License-Identifier: MIT

import Foundation
import zlib

public struct OfficeZIPEntry: Equatable, Sendable {
    public let name: String
    public let method: UInt16
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let crc32: UInt32
    public let localOffset: Int
}

public final class OfficeZIPReader {
    public let entries: [String: OfficeZIPEntry]
    private let fileURL: URL
    private let fileSize: Int

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? Int else { throw OfficeToolError.unavailable("ZIP 大小不可读") }
        self.fileSize = size
        let central = try Self.centralDirectory(fileURL: fileURL, fileSize: size)
        var entries: [String: OfficeZIPEntry] = [:]
        var offset = 0
        for _ in 0..<central.count {
            guard central.data.count - offset >= 46,
                  Self.u32(central.data, offset) == 0x02014B50 else {
                throw OfficeToolError.unsupported("ZIP 中央目录损坏")
            }
            let flags = Self.u16(central.data, offset + 8)
            guard flags & 1 == 0 else { throw OfficeToolError.unsupported("加密 ZIP 条目") }
            let method = Self.u16(central.data, offset + 10)
            guard method == 0 || method == 8 else {
                throw OfficeToolError.unsupported("ZIP 压缩方法 \(method)")
            }
            let nameLength = Int(Self.u16(central.data, offset + 28))
            let extraLength = Int(Self.u16(central.data, offset + 30))
            let commentLength = Int(Self.u16(central.data, offset + 32))
            let next = offset + 46 + nameLength + extraLength + commentLength
            guard next <= central.data.count else { throw OfficeToolError.unsupported("ZIP 条目越界") }
            let nameData = central.data.subdata(in: offset + 46..<offset + 46 + nameLength)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw OfficeToolError.unsupported("ZIP 条目名不是 UTF-8")
            }
            guard Self.safeName(name), entries[name] == nil else {
                throw OfficeToolError.unsupported("ZIP 条目路径不安全: \(String(reflecting: name))")
            }
            var uncompressed = Int(Self.u32(central.data, offset + 24))
            var compressed = Int(Self.u32(central.data, offset + 20))
            var local = Int(Self.u32(central.data, offset + 42))
            if uncompressed == Int(UInt32.max) || compressed == Int(UInt32.max) || local == Int(UInt32.max) {
                let extra = central.data.subdata(in: offset + 46 + nameLength..<offset + 46 + nameLength + extraLength)
                let values = try Self.zip64Values(extra: extra,
                                                  needUncompressed: uncompressed == Int(UInt32.max),
                                                  needCompressed: compressed == Int(UInt32.max),
                                                  needOffset: local == Int(UInt32.max))
                if let value = values.uncompressed { uncompressed = value }
                if let value = values.compressed { compressed = value }
                if let value = values.offset { local = value }
            }
            guard uncompressed <= 64 * 1024 * 1024, compressed <= 64 * 1024 * 1024 else {
                throw OfficeToolError.unsupported("ZIP 条目超过 64 MiB")
            }
            let entry = OfficeZIPEntry(name: name, method: method,
                                       compressedSize: compressed, uncompressedSize: uncompressed,
                                       crc32: Self.u32(central.data, offset + 16), localOffset: local)
            entries[name] = entry
            offset = next
        }
        self.entries = entries
    }

    public func data(for entry: OfficeZIPEntry) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(entry.localOffset))
        guard let header = try handle.read(upToCount: 30), header.count == 30,
              Self.u32(header, 0) == 0x04034B50 else {
            throw OfficeToolError.unsupported("ZIP 本地头损坏")
        }
        let nameLength = Int(Self.u16(header, 26))
        let extraLength = Int(Self.u16(header, 28))
        try handle.seek(toOffset: UInt64(entry.localOffset + 30 + nameLength + extraLength))
        let compressed = try handle.read(upToCount: entry.compressedSize) ?? Data()
        guard compressed.count == entry.compressedSize else {
            throw OfficeToolError.unsupported("ZIP 条目字节不足")
        }
        let output: Data
        switch entry.method {
        case 0:
            output = compressed
        case 8:
            output = try Self.inflate(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw OfficeToolError.unsupported("ZIP 压缩方法 \(entry.method)")
        }
        guard output.count == entry.uncompressedSize, Self.crc(output) == entry.crc32 else {
            throw OfficeToolError.unsupported("ZIP CRC 校验失败")
        }
        return output
    }

    public func data(named name: String) throws -> Data {
        guard let entry = entries[name] else { throw OfficeToolError.unsupported("缺少 ZIP 条目 \(name)") }
        return try data(for: entry)
    }

    private static func centralDirectory(fileURL: URL, fileSize: Int) throws -> (data: Data, count: Int) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let tailSize = min(fileSize, 65_557)
        try handle.seek(toOffset: UInt64(fileSize - tailSize))
        let tail = try handle.read(upToCount: tailSize) ?? Data()
        guard let eocd = tail.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: .backwards)?.lowerBound,
              eocd + 22 <= tail.count,
              Int(u16(tail, eocd + 20)) == tail.count - eocd - 22 else {
            throw OfficeToolError.unsupported("不是 ZIP 文件")
        }
        var count = Int(u16(tail, eocd + 10))
        var size = Int(u32(tail, eocd + 12))
        var offset = Int(u32(tail, eocd + 16))
        if count == 65_535 || size == Int(UInt32.max) || offset == Int(UInt32.max) {
            guard eocd >= 20, u32(tail, eocd - 20) == 0x07064B50 else {
                throw OfficeToolError.unsupported("缺少 Zip64 定位记录")
            }
            let zip64Offset = u64(tail, eocd - 20 + 8)
            guard zip64Offset <= UInt64(fileSize) else {
                throw OfficeToolError.unsupported("Zip64 定位记录越界")
            }
            try handle.seek(toOffset: zip64Offset)
            let zip64 = try handle.read(upToCount: 56) ?? Data()
            guard zip64.count == 56, u32(zip64, 0) == 0x06064B50 else {
                throw OfficeToolError.unsupported("Zip64 记录损坏")
            }
            let zip64Count = u64(zip64, 32)
            let zip64Size = u64(zip64, 40)
            let zip64CentralOffset = u64(zip64, 48)
            guard zip64Count <= 4096, zip64Size <= 16 * 1024 * 1024,
                  zip64CentralOffset <= UInt64(fileSize) else {
                throw OfficeToolError.unsupported("Zip64 中央目录超出预算")
            }
            count = Int(zip64Count)
            size = Int(zip64Size)
            offset = Int(zip64CentralOffset)
        }
        guard count <= 4096, size >= 0, size <= 16 * 1024 * 1024, offset >= 0,
              offset + size <= fileSize else {
            throw OfficeToolError.unsupported("ZIP 中央目录超出预算")
        }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: size) ?? Data()
        guard data.count == size else { throw OfficeToolError.unsupported("ZIP 中央目录不完整") }
        return (data, count)
    }

    private static func zip64Values(extra: Data, needUncompressed: Bool,
                                    needCompressed: Bool, needOffset: Bool) throws
        -> (uncompressed: Int?, compressed: Int?, offset: Int?) {
        var position = 0
        var values: (uncompressed: Int?, compressed: Int?, offset: Int?) = (nil, nil, nil)
        while position + 4 <= extra.count {
            let tag = u16(extra, position)
            let length = Int(u16(extra, position + 2))
            position += 4
            guard position + length <= extra.count else { throw OfficeToolError.unsupported("Zip64 extra 越界") }
            if tag == 1 {
                let required = (needUncompressed ? 8 : 0) + (needCompressed ? 8 : 0) + (needOffset ? 8 : 0)
                guard length >= required else { throw OfficeToolError.unsupported("Zip64 extra 不完整") }
                var cursor = position
                if needUncompressed {
                    values.uncompressed = try Self.int(u64(extra, cursor)); cursor += 8
                }
                if needCompressed {
                    values.compressed = try Self.int(u64(extra, cursor)); cursor += 8
                }
                if needOffset { values.offset = try Self.int(u64(extra, cursor)) }
                return values
            }
            position += length
        }
        throw OfficeToolError.unsupported("缺少 Zip64 大小字段")
    }

    private static func safeName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return false }
        return !name.split(separator: "/").contains("..")
    }

    private static func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw OfficeToolError.unsupported("ZIP inflater 初始化失败")
        }
        defer { inflateEnd(&stream) }
        return try input.withUnsafeBytes { inputBytes in
            guard let source = inputBytes.baseAddress else { throw OfficeToolError.unsupported("ZIP 空输入") }
            var output = Data(count: expectedSize)
            let status = try output.withUnsafeMutableBytes { outputBytes -> Int32 in
                guard let destination = outputBytes.baseAddress else {
                    throw OfficeToolError.unsupported("ZIP 输出为空")
                }
                stream.next_in = UnsafeMutablePointer<UInt8>(mutating: source.assumingMemoryBound(to: UInt8.self))
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.assumingMemoryBound(to: UInt8.self)
                stream.avail_out = uInt(expectedSize)
                return zlib.inflate(&stream, Z_FINISH)
            }
            guard status == Z_STREAM_END, stream.total_out == uLong(expectedSize) else {
                throw OfficeToolError.unsupported("ZIP deflate 解压失败")
            }
            return output
        }
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16
    }

    private static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(u32(data, offset)) | UInt64(u32(data, offset + 4)) << 32
    }

    private static func int(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else { throw OfficeToolError.unsupported("Zip64 整数超出范围") }
        return Int(value)
    }

    fileprivate static func crc(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes -> UInt32 in
            guard let address = bytes.baseAddress else { return 0 }
            return UInt32(zlib.crc32(0, address.assumingMemoryBound(to: Bytef.self), uInt(data.count)))
        }
    }
}

public enum OfficeZIPWriter {
    public static func write(entries: [(name: String, data: Data)], to url: URL,
                             compress: Bool = false) throws {
        guard entries.count <= UInt16.max else { throw OfficeToolError.invalidArguments("ZIP 条目过多") }
        var output = Data()
        var central = Data()
        for entry in entries {
            guard !entry.name.isEmpty, !entry.name.hasPrefix("/"), !entry.name.contains("\\"),
                  !entry.name.split(separator: "/").contains("..") else {
                throw OfficeToolError.invalidArguments("ZIP 条目路径不安全")
            }
            let name = Data(entry.name.utf8)
            let compressed = compress ? try deflate(entry.data) : entry.data
            let method = UInt16(compress ? 8 : 0)
            let crc = OfficeZIPReader.crc(entry.data)
            let localOffset = UInt32(output.count)
            append(&output, UInt32(0x04034B50))
            append(&output, UInt16(20))
            append(&output, UInt16(0))
            append(&output, method)
            append(&output, UInt16(0))
            append(&output, UInt16(0))
            append(&output, crc)
            append(&output, UInt32(compressed.count))
            append(&output, UInt32(entry.data.count))
            append(&output, UInt16(name.count))
            append(&output, UInt16(0))
            output.append(name)
            output.append(compressed)

            append(&central, UInt32(0x02014B50))
            append(&central, UInt16(20))
            append(&central, UInt16(20))
            append(&central, UInt16(0))
            append(&central, method)
            append(&central, UInt16(0))
            append(&central, UInt16(0))
            append(&central, crc)
            append(&central, UInt32(compressed.count))
            append(&central, UInt32(entry.data.count))
            append(&central, UInt16(name.count))
            append(&central, UInt16(0))
            append(&central, UInt16(0))
            append(&central, UInt16(0))
            append(&central, UInt16(0))
            append(&central, UInt32(0))
            append(&central, localOffset)
            central.append(name)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        append(&output, UInt32(0x06054B50))
        append(&output, UInt16(0))
        append(&output, UInt16(0))
        append(&output, UInt16(entries.count))
        append(&output, UInt16(entries.count))
        append(&output, UInt32(central.count))
        append(&output, centralOffset)
        append(&output, UInt16(0))
        try output.write(to: url, options: .atomic)
    }

    private static func deflate(_ input: Data) throws -> Data {
        if input.isEmpty { return Data([0x03, 0x00]) }
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
                            Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw OfficeToolError.unavailable("ZIP deflater 初始化失败")
        }
        defer { deflateEnd(&stream) }
        return try input.withUnsafeBytes { inputBytes in
            guard let source = inputBytes.baseAddress else { throw OfficeToolError.unavailable("ZIP 输入为空") }
            var output = Data(count: Int(deflateBound(&stream, uLong(input.count))))
            let capacity = output.count
            let status = output.withUnsafeMutableBytes { outputBytes -> Int32 in
                stream.next_in = UnsafeMutablePointer<UInt8>(mutating: source.assumingMemoryBound(to: UInt8.self))
                stream.avail_in = uInt(input.count)
                stream.next_out = outputBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                stream.avail_out = uInt(capacity)
                return zlib.deflate(&stream, Z_FINISH)
            }
            guard status == Z_STREAM_END else { throw OfficeToolError.unavailable("ZIP 压缩失败") }
            output.count = Int(stream.total_out)
            return output
        }
    }

    private static func append(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func append(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
