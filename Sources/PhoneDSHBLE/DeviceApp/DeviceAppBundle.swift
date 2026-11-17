// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit

/// Link tool names of device-app-v1 (spec/device/v1/device-app.md §5).
public enum DeviceAppTools {
    public static let info = "app.info"
    public static let begin = "app.begin"
    public static let put = "app.put"
    public static let abort = "app.abort"
    public static let commit = "app.commit"
    public static let run = "app.run"
    public static let stop = "app.stop"
    public static let remove = "app.remove"

    /// §7: an agent-origin `ble_link_call` of any of these is refused before the
    /// journal and the radio. `app.info` stays callable by an agent.
    public static let hostOnly: Set<String> = [begin, put, abort, commit, run, stop, remove]

    /// All eight tools of §5 (host-only plus `app.info`).
    public static let all: Set<String> = hostOnly.union([info])

    /// Staging tools write only a staging area and take no durable receipt (§5).
    /// Only their journal intents may be pruned; `app.commit` never is.
    static let staging: Set<String> = [begin, put, abort]
}

/// One file of a bundle: a relative path and its raw bytes.
public struct DeviceAppFile: Equatable, Sendable {
    public let path: String
    public let bytes: Data
    public init(path: String, bytes: Data) { self.path = path; self.bytes = bytes }
    public var sha256: String { DeviceAppRules.sha256Hex(bytes) }
}

/// The input of an install: what the user confirmed. `digest` is the manifest
/// digest of §4 that the approval is bound to.
public struct DeviceAppBundle: Equatable, Sendable {
    public let name: String
    public let files: [DeviceAppFile]
    public let digest: String
    public init(name: String, files: [DeviceAppFile], digest: String) {
        self.name = name; self.files = files; self.digest = digest
    }
}

/// Limits (§2) and digest (§4). Pure functions; the Bot slice owns the §9 static check.
public enum DeviceAppRules {
    public static let maxFiles = 8
    public static let maxFileBytes = 12288
    public static let maxAppBytes = 24576
    public static let maxChunkBytes = 2048

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func isValidName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...24).contains(bytes.count), let first = bytes.first, (97...122).contains(first) else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }

    public static func isValidPath(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count) else { return false }
        let segments = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(segments.count) else { return false }
        func word(_ text: Substring) -> Bool {
            !text.isEmpty && text.utf8.allSatisfy {
                (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
            }
        }
        for segment in segments.dropLast() where !word(Substring(segment)) { return false }
        let last = segments[segments.count - 1]
        for ext in [".py", ".json"] where last.hasSuffix(ext) {
            return word(last.dropLast(ext.count))
        }
        return false
    }

    /// §4: one line `<path>\t<size>\t<sha256>\n` per file, sorted by the path's UTF-8 bytes.
    public static func manifestDigest(_ files: [(path: String, size: Int, sha256: String)]) -> String {
        let sorted = files.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        let text = sorted.map { "\($0.path)\t\($0.size)\t\($0.sha256)\n" }.joined()
        return sha256Hex(Data(text.utf8))
    }

    public static func manifestDigest(of files: [DeviceAppFile]) -> String {
        manifestDigest(files.map { ($0.path, $0.bytes.count, $0.sha256) })
    }

    /// The first §2 violation of a bundle, or nil. The declared digest must equal
    /// the recomputed one so a mismatched approval can never reach the radio.
    public static func validate(_ bundle: DeviceAppBundle) -> String? {
        guard isValidName(bundle.name) else { return "invalid app name" }
        guard (1...maxFiles).contains(bundle.files.count) else { return "a bundle has 1 to \(maxFiles) files" }
        let paths = bundle.files.map(\.path)
        guard Set(paths).count == paths.count else { return "duplicate file path" }
        guard paths.contains("main.py"), paths.contains("app.json") else { return "main.py and app.json are required" }
        var total = 0
        for file in bundle.files {
            guard isValidPath(file.path) else { return "invalid file path" }
            guard file.bytes.count <= maxFileBytes else { return "file too large" }
            total += file.bytes.count
        }
        guard total <= maxAppBytes else { return "app too large" }
        guard bundle.digest == manifestDigest(of: bundle.files) else { return "declared digest does not match the files" }
        return nil
    }
}
