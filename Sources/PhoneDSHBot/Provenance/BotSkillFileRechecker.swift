// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Filesystem recheck for G-4 `skill.changed` write carriers. The host supplies
/// the already-resolved skills root (for the phone profile
/// `/dsh/home/skills`); this adapter only hashes raw UTF-8 bytes and never
/// writes a skill. Missing/unreadable files are `unavailable`, never current.
public struct BotSkillFileRechecker: BotSkillRechecking {
    public let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    public func recheckSkill(name: String, file: String,
                             expectedSHA256: String) async -> BotSkillRecheckOutcome {
        guard !file.isEmpty, !file.hasPrefix("/"), !file.contains(".."),
              !file.contains("\u{0}") else {
            return .notPerformed
        }
        let candidate = root.appendingPathComponent(file).standardizedFileURL
        let canonicalRoot = root.standardizedFileURL
        guard candidate.path == canonicalRoot.path
                || candidate.path.hasPrefix(canonicalRoot.path + "/") else {
            return .denied(detail: "skill path escaped the skills root")
        }
        guard let data = fileManager.contents(atPath: candidate.path) else {
            return .unavailable(detail: "skill file is missing or unreadable")
        }
        let actual = "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        if actual == expectedSHA256 {
            return .same(atMS: Int64(Date().timeIntervalSince1970 * 1_000))
        }
        return .changed(
            actualSHA256: actual,
            atMS: Int64(Date().timeIntervalSince1970 * 1_000))
    }
}
