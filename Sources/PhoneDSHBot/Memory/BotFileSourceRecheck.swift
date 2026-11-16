// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Resource identity for a file/attachment observation (G-1 r5 §2.3).
///
/// This is an input adapter for the frozen `resource` member, not a second
/// identity authority: the provenance read model owns identity, and this type
/// is replaced by L's `BotProvenanceResource` adapter when that lands.
public struct BotFileResourceIdentity: Sendable, Equatable {
    public let kind: String
    public let key: String
    public let owner: String?
    public let scope: String?

    public init(kind: String = "file", key: String,
                owner: String? = nil, scope: String? = nil) {
        self.kind = kind
        self.key = key
        self.owner = owner
        self.scope = scope
    }
}

/// What the baseline token was computed over. A file byte digest and a record
/// readable-text digest are not interchangeable (PDF/image extraction, BOM,
/// truncation); the rechecker must not compare them as if they were.
public enum BotFileBaseline: Sendable, Equatable {
    /// SHA-256 of the file's raw bytes (`sha256:<hex>`) captured by N at import.
    case fileBytes(String)
    /// SHA-256 of the record's readable text (`sha256:<hex>`). Only a UTF-8
    /// file whose full text was captured can be compared; anything else is
    /// `refresh-not-performed`, never current/changed.
    case recordText(String)
}

public enum BotFileRecheckReason: String, Sendable, Equatable, CaseIterable {
    case noResourceIdentity = "no-resource-identity"
    case scopeMismatch = "resource-scope-mismatch"
    case notFound = "file-not-found"
    case notRegularFile = "not-regular-file"
    case unreadable = "file-unreadable"
    case tooLarge = "file-too-large"
    case noBaseline = "no-baseline"
    /// The baseline and the current read are not known to be over the same
    /// bytes (record text digest vs raw file, binary/non-UTF-8 file).
    case baselineNotComparable = "baseline-not-comparable"
    /// The App has not wired the VFS→host resolver; no read was attempted.
    case providerUnavailable = "refresh-not-performed"
}

public enum BotFileRecheckResult: Sendable, Equatable {
    case unchanged(version: BotKnownSourceVersion, recheckedAtMS: Int64)
    case changed(previous: BotFileBaseline, current: BotKnownSourceVersion,
                 recheckedAtMS: Int64)
    /// The host refused to read: no stable identity or out-of-workspace path.
    case denied(reason: BotFileRecheckReason)
    /// A read was attempted and failed (missing, not regular, unreadable, too
    /// large). The caller must surface `refresh-unavailable`.
    case unavailable(reason: BotFileRecheckReason)
    /// No comparison was performed; the caller must surface
    /// `refresh-not-performed`, never current.
    case notPerformed(reason: BotFileRecheckReason)

    public var version: BotKnownSourceVersion? {
        switch self {
        case let .unchanged(version, _), let .changed(_, version, _): return version
        case .denied, .unavailable, .notPerformed: return nil
        }
    }
}

/// Resolves a file resource key to a host URL. The App owns the VFS
/// `/dsh/workspace/...` → materialized host mapping and supplies this; the
/// rechecker never guesses a filesystem root.
public protocol BotFileURLResolving: Sendable {
    func fileURL(for resource: BotFileResourceIdentity, botID: String) -> URL?
}

/// The real file recheck producer L consumes on the next read. The resolver
/// owns the implementation; L only decides the resulting state.
public protocol BotFileSourceRechecking: Sendable {
    func recheck(_ resource: BotFileResourceIdentity, botID: String,
                 baseline: BotFileBaseline?) async -> BotFileRecheckResult
}

/// Real file producer for R2/E3: every call stats and hashes the current file.
/// There is no cached version and no fallback that would confuse a record text
/// digest with raw file bytes.
public struct BotFileSourceRechecker: BotFileSourceRechecking, Sendable {
    public static let defaultByteLimit = 64 * 1024 * 1024
    public static let chunkSize = 1024 * 1024

    private let locator: any BotFileURLResolving
    private let now: @Sendable () -> Int64
    private let byteLimit: Int

    public init(locator: any BotFileURLResolving,
                byteLimit: Int = BotFileSourceRechecker.defaultByteLimit,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1_000)
                }) {
        self.locator = locator
        self.now = now
        self.byteLimit = max(1, byteLimit)
    }

    public func recheck(_ resource: BotFileResourceIdentity,
                        botID: String,
                        baseline: BotFileBaseline?) async -> BotFileRecheckResult {
        guard resource.kind == "file", !resource.key.isEmpty,
              resource.key.unicodeScalars.count <= 512 else {
            return .denied(reason: .noResourceIdentity)
        }
        guard let url = locator.fileURL(for: resource, botID: botID) else {
            return .denied(reason: .noResourceIdentity)
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard let values else { return .unavailable(reason: .notFound) }
        guard values.isRegularFile == true else {
            return .unavailable(reason: .notRegularFile)
        }
        if let size = values.fileSize, size > byteLimit {
            return .unavailable(reason: .tooLarge)
        }
        guard let baseline else { return .notPerformed(reason: .noBaseline) }

        switch baseline {
        case let .fileBytes(token):
            guard let digest = Self.sha256(of: url, byteLimit: byteLimit) else {
                return .unavailable(reason: .unreadable)
            }
            let known = BotKnownSourceVersion(
                kind: .contentSHA256, value: "sha256:" + digest,
                observedAtMS: now(), basisRef: nil, subject: .fileBytes)
            if token == known.value {
                return .unchanged(version: known, recheckedAtMS: now())
            }
            return .changed(previous: baseline, current: known, recheckedAtMS: now())
        case let .recordText(token):
            // G-1 r8: a sourceVersion must be the raw file bytes. A record-text
            // digest is only comparable when it happens to equal sha256(raw
            // bytes) -- then no extraction/BOM/truncation could have occurred.
            // A mismatch is NOT evidence of change (PDF/image extraction), so
            // it is refresh-not-performed, never changed.
            guard let digest = Self.sha256(of: url, byteLimit: byteLimit) else {
                return .unavailable(reason: .unreadable)
            }
            let known = BotKnownSourceVersion(
                kind: .contentSHA256, value: "sha256:" + digest,
                observedAtMS: now(), basisRef: nil, subject: .fileBytes)
            if token == known.value {
                return .unchanged(version: known, recheckedAtMS: now())
            }
            return .notPerformed(reason: .baselineNotComparable)
        }
    }

    /// Streaming SHA-256 of the file's raw bytes. Returns nil on any read error
    /// or when the file grows past the byte limit while being hashed.
    static func sha256(of url: URL, byteLimit: Int) -> String? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return nil
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            total += chunk.count
            if total > byteLimit { return nil }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
