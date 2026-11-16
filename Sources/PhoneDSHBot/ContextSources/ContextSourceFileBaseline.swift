// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// The file/attachment baseline metadata N hands to the derivation writer.
///
/// G-1 r13: a `content-sha256` over raw file bytes carries
/// `subject:"file-bytes"`; a text/extracted digest is `record-text` (or absent,
/// which is conservatively record-text). This value is metadata only: the
/// digest is never copied into a model-visible body.
public struct BotContextFileBaseline: Codable, Sendable, Equatable {
    public static let fileBytesSubject = "file-bytes"

    public var subject: String
    public var sha256: String
    public var sourceVersion: BotContextSourceVersion
    public var resource: BotContextResource

    public init(subject: String = BotContextFileBaseline.fileBytesSubject,
                sha256: String,
                sourceVersion: BotContextSourceVersion,
                resource: BotContextResource) throws {
        guard subject == Self.fileBytesSubject else {
            throw BotContextSourceError.invalidRequest("a file baseline requires subject=file-bytes")
        }
        let value = sha256.lowercased()
        guard value.hasPrefix("sha256:"),
              value.dropFirst("sha256:".count).count == 64,
              value.dropFirst("sha256:".count).allSatisfy({ $0.isHexDigit }) else {
            throw BotContextSourceError.invalidRequest("file baseline requires sha256:<64hex>")
        }
        guard resource.kind == .file else {
            throw BotContextSourceError.invalidRequest("file baseline requires a file resource")
        }
        self.subject = subject
        self.sha256 = value
        self.sourceVersion = sourceVersion
        self.resource = resource
    }
}


public extension BotContextFileBaseline {
    /// Stream the real file bytes (bounded) and build the import-time baseline.
    /// The returned version is `content-sha256` + `subject:file-bytes` and the
    /// resource is `file` identity; callers supply the normalized VFS path/file
    /// id. The digest is metadata only, never a model-visible body.
    static func compute(fileAt url: URL,
                        ownerBotID: String,
                        resourceKey: String) throws -> BotContextFileBaseline {
        guard !ownerBotID.isEmpty else {
            throw BotContextSourceError.invalidRequest("file baseline requires an owner bot")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            total += Int64(chunk.count)
            guard total <= BotAttachmentPolicy.maxBytes else {
                throw BotContextSourceError.invalidRequest("file exceeds the attachment size limit")
            }
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let resource = try BotContextResource(
            kind: .file, key: resourceKey, owner: ownerBotID)
        return try BotContextFileBaseline(
            sha256: "sha256:\(hex)",
            sourceVersion: .fileBytes("sha256:\(hex)"),
            resource: resource)
    }
}

public extension BotContextObservation {
    /// Build the file baseline only for a user-selected media/share observation
    /// whose version is a real byte digest. `resourceKey` is the Caller's
    /// normalized VFS path/file id (G-1 §2.3); without it the digest is the
    /// stable fallback identity and the derivation writer must still verify it.
    func fileBaseline(ownerBotID: String,
                      resourceKey: String? = nil) -> BotContextFileBaseline? {
        guard !ownerBotID.isEmpty else { return nil }
        let isFileObservation =
            (source == .selectedMedia && kind == .mediaSelected)
            || (source == .externalEntry && kind == .externalShareItem)
        guard isFileObservation else { return nil }
        guard case .known(let basis, let value, let observedAt, _, _) = sourceVersion,
              basis == .contentSHA256,
              value.hasPrefix("sha256:") else { return nil }
        let key = resourceKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey = (key?.isEmpty == false) ? key! : "file:\(value)"
        guard let resource = try? BotContextResource(
            kind: .file, key: resolvedKey, owner: ownerBotID) else { return nil }
        return try? BotContextFileBaseline(
            sha256: value,
            sourceVersion: .known(basis: basis, value: value, observedAt: observedAt,
                                  basisRef: nil, subject: .fileBytes),
            resource: resource)
    }
}
