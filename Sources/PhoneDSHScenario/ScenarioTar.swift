// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: a minimal ustar writer.
//
// Every runner writes `workspace.tar` with this small, standard POSIX ustar
// writer. G2-FIX-5 removed the macOS `/usr/bin/tar` branch: bsdtar can add
// AppleDouble `._` members depending on the external process environment, so
// the archive's membership was not reproducible. The judge extracts the same
// ustar format on every platform; `.git` entries are ordinary files.

import Foundation

public enum ScenarioTar {
    private static let blockSize = 512

    /// Archives `directory` (its contents, not its name) to `archive`.
    public static func archive(directory: URL, to archive: URL,
                        fileManager: FileManager = .default) throws {
        var entries: [(relative: String, url: URL, isDirectory: Bool)] = []
        let prefix = directory.standardizedFileURL.path + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        if let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: []) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let isDirectory = values?.isDirectory == true
                guard isDirectory || values?.isRegularFile == true else { continue }
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(prefix) else { continue }
                var relative = String(full.dropFirst(prefix.count))
                if relative.isEmpty { continue }
                if isDirectory, !relative.hasSuffix("/") { relative += "/" }
                entries.append((relative, url, isDirectory))
            }
        }
        entries.sort { $0.relative < $1.relative }

        var body = Data()
        for entry in entries {
            let attributes = try? fileManager.attributesOfItem(atPath: entry.url.path)
            let permissions = (attributes?[.posixPermissions] as? NSNumber)?.uint32Value
                ?? (entry.isDirectory ? 0o755 : 0o644)
            let data: Data
            if entry.isDirectory {
                data = Data()
            } else {
                data = try Data(contentsOf: entry.url)
            }
            body.append(header(name: entry.relative,
                               mode: permissions & 0o7777,
                               size: data.count,
                               type: entry.isDirectory ? "5" : "0"))
            body.append(data)
            let padding = (blockSize - data.count % blockSize) % blockSize
            if padding > 0 { body.append(Data(count: padding)) }
        }
        // End-of-archive marker: two zero blocks.
        body.append(Data(count: blockSize * 2))
        try body.write(to: archive, options: .atomic)
    }

    private static func header(name: String, mode: UInt32, size: Int,
                               type: String) -> Data {
        var header = [UInt8](repeating: 0, count: blockSize)
        func put(_ value: String, at offset: Int, length: Int) {
            let bytes = Array(value.utf8.prefix(length))
            for (index, byte) in bytes.enumerated() {
                header[offset + index] = byte
            }
        }
        func octal(_ value: UInt64, at offset: Int, length: Int) {
            let text = String(value, radix: 8)
            let padded = String(repeating: "0", count: max(1, length - 1 - text.count)) + text
            put(padded, at: offset, length: length - 1)
            header[offset + length - 1] = 0
        }
        // POSIX ustar requires the name in the 100-byte prefix unless it is
        // longer; workspace paths are short, but fall back to the prefix field
        // when a path does not fit.
        if name.utf8.count <= 100 {
            put(name, at: 0, length: 100)
        } else {
            let bytes = Array(name.utf8)
            // Split at a path separator so the prefix fits 155 bytes.
            var split = bytes.count - 100
            while split < bytes.count, split > 0, bytes[split] != UInt8(ascii: "/") {
                split += 1
            }
            if split <= 0 || split >= bytes.count { split = bytes.count - 100 }
            put(String(decoding: bytes[..<split], as: UTF8.self), at: 345, length: 155)
            put(String(decoding: bytes[split...], as: UTF8.self), at: 0, length: 100)
        }
        octal(UInt64(mode), at: 100, length: 8)
        octal(0, at: 108, length: 8)
        octal(0, at: 116, length: 8)
        octal(UInt64(size), at: 124, length: 12)
        octal(0, at: 136, length: 12)
        put("        ", at: 148, length: 8)  // checksum placeholder
        put(type, at: 156, length: 1)
        put("ustar", at: 257, length: 6)
        put("00", at: 263, length: 2)
        put("root", at: 265, length: 32)
        put("root", at: 297, length: 32)
        let checksum = header.reduce(0) { $0 + UInt64($1) }
        let text = String(checksum, radix: 8)
        let padded = String(repeating: "0", count: max(1, 6 - text.count)) + text
        for (index, byte) in Array(padded.utf8).prefix(6).enumerated() {
            header[148 + index] = byte
        }
        header[154] = 0
        header[155] = UInt8(ascii: " ")
        return Data(header)
    }
}
