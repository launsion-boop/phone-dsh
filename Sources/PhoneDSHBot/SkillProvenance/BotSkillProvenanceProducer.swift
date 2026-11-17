// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public enum BotSkillProvenanceError: Error, Equatable, Sendable {
    case pathOutsideSkillRoots
    case invalidFileName
    case notRegularFile
    case symbolicLink
    case tooLarge
    case unreadable
    case fileStillPresent
    case missingPreviousVersion
}

/// Records one real skill file write/delete after the bytes are final.
///
/// The producer owns path classification and byte reads only. L owns the
/// durable `skill.changed` event, monotonic revision, and snapshot lookup; the
/// closures below are L's `recordSkillWrite` and
/// `latestSkillChange(identity:)`. No skill store, revision cache, or scan of
/// unrelated files is introduced.
public struct BotSkillProvenanceProducer: Sendable {
    public typealias Recorder = @Sendable (BotSkillWriteRequest) async throws -> BotDerivedRef
    public typealias Latest = @Sendable (BotSkillIdentity) async throws -> BotSkillChangeSnapshot?

    public static let maximumBytes = 2 * 1024 * 1024

    private let botRoot: String
    private let roots: any BotSkillRootResolving
    private let recorder: Recorder
    private let latest: Latest
    private let now: @Sendable () -> Int64

    public init(botRoot: String,
                roots: any BotSkillRootResolving,
                recorder: @escaping Recorder,
                latest: @escaping Latest,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1_000)
                }) {
        self.botRoot = botRoot
        self.roots = roots
        self.recorder = recorder
        self.latest = latest
        self.now = now
    }

    /// A successful Bot `write`/`edit` under `<botRoot>/.dsh/skills` or
    /// `.agents/skills`. Returns nil for a non-skill path so the runtime can
    /// call this for every successful write/edit.
    public func recordBotWrite(vfsPath: String, botID: String,
                               sessionID: String?,
                               sources: [BotDerivationSource] = [],
                               creatorRecord: String? = nil,
                               creatorContentSHA256: String? = nil) async throws
        -> BotDerivedRef? {
        guard let target = classify(vfsPath: vfsPath, botID: botID) else { return nil }
        let data = try readFinalBytes(target.url)
        var sources = sources
        if let creatorRecord, let creatorContentSHA256 {
            if Self.sha256(data) != creatorContentSHA256 {
                // The action record cannot stand as the creator of different
                // final bytes (truncated args, redaction, or a later mutation).
                sources.removeAll { $0.record == creatorRecord && $0.role == .creator }
            } else {
                // Bind the validation to the creator source so a later reader
                // can require the same final content hash, not role alone.
                let version = BotProvenanceSourceVersion.known(
                    basis: .contentSHA256, value: creatorContentSHA256,
                    subject: .fileBytes)
                sources = sources.map {
                    $0.record == creatorRecord && $0.role == .creator
                        ? BotDerivationSource(record: $0.record, role: .creator,
                                              sourceVersion: version)
                        : $0
                }
            }
        }
        let snapshot = try await latest(BotSkillIdentity(
            source: target.source, ownerBotID: target.owner, name: target.name))
        let previous = snapshot?.action == "write" ? snapshot?.contentSHA256 : nil
        let request = BotSkillWriteRequest(
            name: target.name, file: target.file,
            revision: (snapshot?.revision ?? 0) + 1,
            action: .write, contentSHA256: Self.sha256(data), bytes: data.count,
            previousSHA256: previous,
            author: BotSkillChangeAuthor(kind: "bot", botID: botID,
                                         sessionID: sessionID),
            atMS: now(), sources: sources,
            source: target.source, ownerBotID: target.owner)
        return try await recorder(request)
    }

    /// A real Bot project-root delete observed from the filesystem lifecycle.
    /// The file must be gone (ENOENT); a read/permission failure is not a
    /// delete and must not call this method. Revision/previous come from L.
    public func recordBotDelete(vfsPath: String, botID: String,
                                sessionID: String?) async throws
        -> BotDerivedRef? {
        guard let target = classify(vfsPath: vfsPath, botID: botID) else { return nil }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.url.path,
                                          isDirectory: &isDirectory) {
            throw BotSkillProvenanceError.fileStillPresent
        }
        let snapshot = try await latest(BotSkillIdentity(
            source: target.source, ownerBotID: target.owner, name: target.name))
        guard let snapshot, snapshot.action == "write",
              let previous = snapshot.contentSHA256 else {
            throw BotSkillProvenanceError.missingPreviousVersion
        }
        let request = BotSkillWriteRequest(
            name: target.name, file: target.file,
            revision: snapshot.revision + 1, action: .delete,
            contentSHA256: nil, bytes: nil, previousSHA256: previous,
            author: BotSkillChangeAuthor(kind: "bot", botID: botID,
                                         sessionID: sessionID),
            atMS: now(), sources: [],
            source: target.source, ownerBotID: target.owner)
        return try await recorder(request)
    }

    /// A real feature-admin `SkillsStore.write` under `/dsh/home/skills`.
    public func recordUserDshWrite(fileName: String,
                                   sources: [BotDerivationSource] = []) async throws
        -> BotDerivedRef? {
        guard let target = userDshTarget(fileName: fileName) else { return nil }
        let data = try readFinalBytes(target.url)
        let snapshot = try await latest(BotSkillIdentity(
            source: .userDsh, ownerBotID: nil, name: target.name))
        let previous = snapshot?.action == "write" ? snapshot?.contentSHA256 : nil
        let request = BotSkillWriteRequest(
            name: target.name, file: target.file,
            revision: (snapshot?.revision ?? 0) + 1,
            action: .write, contentSHA256: Self.sha256(data), bytes: data.count,
            previousSHA256: previous,
            author: BotSkillChangeAuthor(kind: "user"),
            atMS: now(), sources: sources,
            source: .userDsh, ownerBotID: nil)
        return try await recorder(request)
    }

    /// A real feature-admin `SkillsStore.delete` under `/dsh/home/skills`.
    /// The file must already be gone; the previous hash comes from the latest
    /// durable write, never from a directory scan.
    public func recordUserDshDelete(fileName: String,
                                     sources: [BotDerivationSource] = []) async throws
        -> BotDerivedRef? {
        guard let target = userDshTarget(fileName: fileName) else { return nil }
        try requireAbsent(target.url)
        let snapshot = try await latest(BotSkillIdentity(
            source: .userDsh, ownerBotID: nil, name: target.name))
        guard let snapshot, snapshot.action == "write",
              let previous = snapshot.contentSHA256 else {
            throw BotSkillProvenanceError.missingPreviousVersion
        }
        let request = BotSkillWriteRequest(
            name: target.name, file: target.file,
            revision: snapshot.revision + 1, action: .delete,
            contentSHA256: nil, bytes: nil, previousSHA256: previous,
            author: BotSkillChangeAuthor(kind: "user"),
            atMS: now(), sources: sources,
            source: .userDsh, ownerBotID: nil)
        return try await recorder(request)
    }

    // MARK: - path classification

    private struct Target {
        var file: String
        var name: String
        var source: BotSkillSource
        var owner: String?
        var url: URL
    }

    private func classify(vfsPath: String, botID: String) -> Target? {
        let path: String
        if vfsPath.hasPrefix("/") {
            path = vfsPath
        } else {
            path = botRoot.hasSuffix("/") ? botRoot + vfsPath : botRoot + "/" + vfsPath
        }
        let prefix = botRoot.hasSuffix("/") ? botRoot : botRoot + "/"
        for (suffix, source) in [(".dsh/skills/", BotSkillSource.projectDsh),
                                 (".agents/skills/", .projectAgents)] {
            guard path.hasPrefix(prefix + suffix) else { continue }
            let file = String(path.dropFirst((prefix + suffix).count))
            guard let name = Self.parseFlatFile(file),
                  let root = roots.root(for: source, ownerBotID: botID) else {
                return nil
            }
            return Target(file: file, name: name, source: source, owner: botID,
                          url: root.appendingPathComponent(file))
        }
        return nil
    }

    private func userDshTarget(fileName: String) -> Target? {
        guard let name = Self.parseFlatFile(fileName),
              let root = roots.root(for: .userDsh, ownerBotID: nil) else {
            return nil
        }
        return Target(file: fileName, name: name, source: .userDsh, owner: nil,
                      url: root.appendingPathComponent(fileName))
    }

    private static func parseFlatFile(_ file: String) -> String? {
        guard !file.isEmpty, file.hasSuffix(".md"),
              !file.contains("/"), !file.contains("\\"), !file.contains("\u{0}"),
              file.unicodeScalars.count <= 68 else { return nil }
        let name = String(file.dropLast(3))
        guard !name.isEmpty, name.unicodeScalars.count <= 64,
              name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#,
                         options: .regularExpression) != nil else { return nil }
        return name
    }

    /// Strict ENOENT check: an unreadable/permission-denied file is not a
    /// delete. Only `NSFileReadNoSuchFileError`/`NSFileNoSuchFileError` pass.
    private func requireAbsent(_ url: URL) throws {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            throw BotSkillProvenanceError.fileStillPresent
        } catch let error as BotSkillProvenanceError {
            throw error
        } catch let error as NSError {
            guard error.code == NSFileReadNoSuchFileError
                    || error.code == NSFileNoSuchFileError else {
                throw BotSkillProvenanceError.unreadable
            }
        }
    }

    private func readFinalBytes(_ url: URL) throws -> Data {
        let root = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path != root.path,
              resolved.path.hasPrefix(root.path + "/") else {
            throw BotSkillProvenanceError.pathOutsideSkillRoots
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? resolved.resourceValues(forKeys: keys) else {
            throw BotSkillProvenanceError.unreadable
        }
        guard values.isSymbolicLink != true else {
            throw BotSkillProvenanceError.symbolicLink
        }
        guard values.isRegularFile == true else {
            throw BotSkillProvenanceError.notRegularFile
        }
        guard let size = values.fileSize, size <= Self.maximumBytes else {
            throw BotSkillProvenanceError.tooLarge
        }
        guard let data = try? Data(contentsOf: resolved, options: .mappedIfSafe) else {
            throw BotSkillProvenanceError.unreadable
        }
        guard data.count <= Self.maximumBytes else {
            throw BotSkillProvenanceError.tooLarge
        }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
    }
}
