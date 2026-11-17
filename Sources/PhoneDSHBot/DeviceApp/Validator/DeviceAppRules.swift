// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Name, path, title, manifest and digest rules of `spec/device/v1/device-app.md`
/// (`device-app-v1`, §2-§4). Pure functions; the static program check is in
/// `DeviceAppValidator`.
public enum DeviceAppRules {
    public static let fileMaxBytes = 12288
    public static let permissions: Set<String> = ["audio", "mic", "battery"]

    /// `^[a-z][a-z0-9_]{0,23}$`. Unlike a Python `$`, a trailing newline is not accepted.
    public static func isValidName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...24).contains(bytes.count), (0x61...0x7A).contains(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
    }

    /// 1-3 segments of `[A-Za-z0-9_-]`, directories without extension, the last one
    /// `stem.py` or `stem.json`, at most 64 characters, no leading `.`.
    public static func isValidPath(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count) else { return false }
        let segments = bytes.split(separator: 0x2F, omittingEmptySubsequences: false)
        guard (1...3).contains(segments.count) else { return false }
        func isSegmentByte(_ b: UInt8) -> Bool {
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x5F || b == 0x2D
        }
        for directory in segments.dropLast() {
            guard !directory.isEmpty, directory.allSatisfy(isSegmentByte) else { return false }
        }
        let file = Array(segments.last!)
        guard let dot = file.lastIndex(of: 0x2E), dot > 0 else { return false }
        let stem = file[..<dot]
        let ext = String(decoding: file[(dot + 1)...], as: UTF8.self)
        return stem.allSatisfy(isSegmentByte) && (ext == "py" || ext == "json")
    }

    /// 1-20 Unicode scalars, none of general category Cc or Cf.
    public static func isValidTitle(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...20).contains(scalars.count) else { return false }
        return !scalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }
    }

    /// §3: closed object `name`, `title`, `version` (integer >= 1), `perms`. Duplicate keys at any
    /// depth, any extra member and a `name` different from `appName` are invalid.
    public static func isValidManifest(appName: String, json: String) -> Bool {
        guard let root = DeviceAppJSON.parse(json), case .object(let members) = root, members.count == 4 else { return false }
        func member(_ name: String) -> DeviceAppJSON.Value? {
            let key = Array(name.utf8)
            return members.first { $0.key == key }?.value
        }
        guard case .string(let name)? = member("name"), Array(name.utf8) == Array(appName.utf8), isValidName(name),
              case .string(let title)? = member("title"), isValidTitle(title),
              case .integer(let version)? = member("version"), !version.hasPrefix("-"), version != "0",
              case .array(let perms)? = member("perms") else { return false }
        var seen = Set<[UInt8]>()
        for item in perms {
            guard case .string(let perm) = item,
                  permissions.contains(where: { Array($0.utf8) == Array(perm.utf8) }),
                  seen.insert(Array(perm.utf8)).inserted else { return false }
        }
        // 4 members, all four required names resolved above and no duplicates (parser) => closed.
        return true
    }

    public struct FileEntry: Equatable, Sendable {
        public let path: String
        public let size: Int
        public let sha256: String
        public init(path: String, size: Int, sha256: String) {
            self.path = path; self.size = size; self.sha256 = sha256
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Path, UTF-8 size and sha256 of each file's text, in path byte order.
    public static func fileEntries(files: [String: String]) -> [FileEntry] {
        files.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }.map { path in
            let data = Data(files[path]!.utf8)
            return FileEntry(path: path, size: data.count, sha256: sha256Hex(data))
        }
    }

    /// §4: sha256 of `<path>\t<size>\t<sha256>\n` lines sorted by the path's UTF-8 bytes.
    public static func manifestDigest(_ entries: [FileEntry]) -> String {
        let sorted = entries.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        let text = sorted.map { "\($0.path)\t\($0.size)\t\($0.sha256)\n" }.joined()
        return sha256Hex(Data(text.utf8))
    }
}
