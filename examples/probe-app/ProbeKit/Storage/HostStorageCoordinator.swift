// SPDX-License-Identifier: MIT
// W3 host-internal storage: measurement, tiering and the five-level policy.
//
// The authoritative stores (WAL, materialized copy, journal, steps, exec and
// response entries whose deletion condition does not hold) stay in the App
// container's durable tree. Only derived data moves under
// `Library/Caches/pdsh/<workspace_id>/` (budgets.md §9, wal.md §12,
// gateway-security.md §11). Unsent outbox entries and their attachment bytes
// are user data: they are counted for the aggregate budget and are never
// deleted at any level.

import Foundation
import PhoneDSHController
import PhoneDSHGateway
import PhoneDSHLog

public struct HostStoragePaths: Equatable, Sendable {
    public var workspaceRoot: URL
    public var documentsRoot: URL
    public var cachesRoot: URL

    public init(workspaceRoot: URL, documentsRoot: URL, cachesRoot: URL) {
        self.workspaceRoot = workspaceRoot
        self.documentsRoot = documentsRoot
        self.cachesRoot = cachesRoot
    }

    public var overlayCacheRoot: URL { cachesRoot }
    public var responseLogCacheRoot: URL {
        cachesRoot.appendingPathComponent("response-log", isDirectory: true)
    }
    public var transcriptSnapshotCacheRoot: URL {
        cachesRoot.appendingPathComponent("transcript-snapshots", isDirectory: true)
    }
    public var outboxRoot: URL {
        documentsRoot.appendingPathComponent("send-outbox", isDirectory: true)
    }
    public var outboxAttachmentsRoot: URL {
        outboxRoot.appendingPathComponent("attachments", isDirectory: true)
    }
}

public struct HostStorageApplyReport: Equatable, Sendable {
    public var level: HostStorageLevel
    public var removedBytes: Int
    public var removedPaths: [String]
    /// User data that was deliberately left alone (outbox attachments).
    public var preservedUserBytes: Int
    public var signal: HostStorageSignal?

    public init(level: HostStorageLevel,
                removedBytes: Int = 0,
                removedPaths: [String] = [],
                preservedUserBytes: Int = 0,
                signal: HostStorageSignal? = nil) {
        self.level = level
        self.removedBytes = removedBytes
        self.removedPaths = removedPaths
        self.preservedUserBytes = preservedUserBytes
        self.signal = signal
    }
}

/// Measures the App container once per level evaluation. Hard links are counted
/// once across every category, so the overlay cache and its per-boot link do
/// not inflate `hostInternalBytes`.
public struct HostStorageScanner: Sendable {
    public var paths: HostStoragePaths

    public init(paths: HostStoragePaths) {
        self.paths = paths
    }

    public func scan(fileManager: FileManager = .default) -> HostStorageUsage {
        var seen = Set<String>()
        let root = paths.workspaceRoot
        let walSegments = bytes(at: root.appendingPathComponent("wal", isDirectory: true),
                                seen: &seen, fileManager: fileManager)
        // W6 §14.1/§14.6: the content-addressed blob store is part of the WAL's
        // live set (budgets.md §9 counts `hostInternalBytes` as segments + live
        // blobs). Every blob is one immutable regular file, and `seen` keeps a
        // repeated inode from being counted twice. The materialized copy is a
        // clonefile (COW, separate inode) or a copy, so blob + materialized is
        // an upper bound on physical bytes, never an undercount. Orphan blobs
        // only exist until the next §14.5 GC; counting them is the conservative
        // direction, and this scanner never moves or deletes anything here.
        let blobs = bytes(at: root.appendingPathComponent("blobs", isDirectory: true),
                          seen: &seen, fileManager: fileManager)
        let wal = walSegments + blobs
        let materialized = bytes(at: root.appendingPathComponent("materialized", isDirectory: true),
                                 seen: &seen, fileManager: fileManager)
        let journal = bytes(at: root.appendingPathComponent("journal.xljournal"),
                            seen: &seen, fileManager: fileManager)
        let steps = bytes(at: root.appendingPathComponent("steps", isDirectory: true),
                          seen: &seen, fileManager: fileManager)
        let exec = bytes(at: root.appendingPathComponent("exec", isDirectory: true),
                         seen: &seen, fileManager: fileManager)
        let responseLog = bytes(at: root.appendingPathComponent("response-log", isDirectory: true),
                                seen: &seen, fileManager: fileManager)
            + bytes(at: paths.responseLogCacheRoot, seen: &seen, fileManager: fileManager)
        let overlay = overlayBytes(seen: &seen, fileManager: fileManager)
        let transcripts = bytes(at: paths.documentsRoot
            .appendingPathComponent("transcript-snapshots", isDirectory: true),
                                seen: &seen, fileManager: fileManager)
            + bytes(at: paths.transcriptSnapshotCacheRoot,
                    seen: &seen, fileManager: fileManager)
        // Only attachment bytes count toward the aggregate. The entry JSON is
        // small and remains in the durable outbox either way.
        let outbox = bytes(at: paths.outboxAttachmentsRoot,
                           seen: &seen, fileManager: fileManager)
        var workspaceSeen = Set<String>()
        let workspace = bytes(at: root
            .appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true),
                              seen: &workspaceSeen, fileManager: fileManager)
        let volume = volumeValues(for: root)
        return HostStorageUsage(
            walBytes: wal,
            materializedBytes: materialized,
            journalBytes: journal,
            stepsBytes: steps,
            execBytes: exec,
            responseLogBytes: responseLog,
            overlayCacheBytes: overlay,
            transcriptSnapshotBytes: transcripts,
            outboxAttachmentBytes: outbox,
            workspaceLogicalBytes: workspace,
            availableImportantBytes: volume.available,
            volumeBytes: volume.total)
    }

    private func overlayBytes(seen: inout Set<String>, fileManager: FileManager) -> Int {
        var total = 0
        for directory in [paths.overlayCacheRoot,
                          paths.workspaceRoot] {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            for file in files {
                let name = file.lastPathComponent
                guard name == "overlay-cache.tar"
                    || name == "overlay-cache.json"
                    || (name.hasPrefix("overlay-") && name.hasSuffix(".tar")) else {
                    continue
                }
                total += bytes(at: file, seen: &seen, fileManager: fileManager)
            }
        }
        return total
    }

    /// Byte sum of a file or directory tree, with hard links counted once.
    public func bytes(at url: URL, fileManager: FileManager = .default) -> Int {
        var seen = Set<String>()
        return bytes(at: url, seen: &seen, fileManager: fileManager)
    }

    private func bytes(at url: URL, seen: inout Set<String>, fileManager: FileManager) -> Int {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return fileBytes(at: url, seen: &seen, fileManager: fileManager)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in false }) else {
            return 0
        }
        var total = 0
        for case let child as URL in enumerator {
            total += fileBytes(at: child, seen: &seen, fileManager: fileManager)
        }
        return total
    }

    private func fileBytes(at url: URL, seen: inout Set<String>, fileManager: FileManager) -> Int {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else { return 0 }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return size
        }
        let device = (attributes[.systemNumber] as? NSNumber)?.intValue ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? 0
        if inode != 0 {
            let identity = "\(device):\(inode)"
            if seen.contains(identity) { return 0 }
            seen.insert(identity)
        }
        return size
    }

    private func volumeValues(for url: URL) -> (available: Int, total: Int?) {
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                      .volumeAvailableCapacityKey,
                      .volumeTotalCapacityKey])
        let important = values?.volumeAvailableCapacityForImportantUsage
            ?? values?.volumeAvailableCapacity
        let available = important.map { Int($0) } ?? Int.max
        let total: Int? = values?.volumeTotalCapacity
        return (max(0, available), total.map { max(0, $0) })
    }

    /// Largest regular files under the workspace, for the level-3 signal.
    /// Paths are relative to `materialized/workspace`; no absolute container
    /// path leaves the model layer.
    public func largestWorkspaceFiles(limit: Int = 5,
                                      fileManager: FileManager = .default) -> [HostStorageFile] {
        let root = paths.workspaceRoot
            .appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in false }) else { return [] }
        var files: [HostStorageFile] = []
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            let relative = child.path.replacingOccurrences(of: root.path + "/", with: "")
            files.append(HostStorageFile(relativePath: relative, byteCount: size))
        }
        return files.sorted {
            if $0.byteCount != $1.byteCount { return $0.byteCount > $1.byteCount }
            return $0.relativePath < $1.relativePath
        }.prefix(max(0, limit)).map { $0 }
    }
}

/// Applies one policy decision. It never deletes `home/`, `workspace/`, a
/// session, an un-journaled step, an outbox entry or outbox attachment bytes.
public actor HostStorageCoordinator {
    public let paths: HostStoragePaths
    public var policy: HostStoragePolicy

    private let scanner: HostStorageScanner

    public init(paths: HostStoragePaths, policy: HostStoragePolicy = .standard) {
        self.paths = paths
        self.policy = policy
        self.scanner = HostStorageScanner(paths: paths)
    }

    public func scan() -> HostStorageUsage {
        return scanner.scan()
    }

    public func decision(workspaceBucketBytes: Int,
                         writeWouldFail: Bool = false) -> HostStorageDecision {
        let usage = scanner.scan()
        return policy.decision(for: usage,
                               workspaceBucketBytes: workspaceBucketBytes,
                               writeWouldFail: writeWouldFail,
                               largestFiles: scanner.largestWorkspaceFiles())
    }

    /// Runs the automatic actions of one level. `eligibleResponseKeys` must be
    /// exactly the response entries whose step is journaled and durable; the
    /// response log itself refuses a key with a resume in flight. A `.four`
    /// decision prunes first, then throws the explicit quota error.
    @discardableResult
    public func apply(_ decision: HostStorageDecision,
                      responseLog: ResponseLog? = nil,
                      eligibleResponseKeys: Set<String> = []) async throws
        -> HostStorageApplyReport {
        var report = HostStorageApplyReport(level: decision.level,
                                            signal: decision.signal)
        let usage = scanner.scan()
        report.preservedUserBytes = usage.outboxAttachmentBytes

        if decision.level.rawValue >= HostStorageLevel.one.rawValue {
            let pruned = await pruneRebuildableCaches(
                responseLog: responseLog,
                eligibleResponseKeys: eligibleResponseKeys)
            report.removedBytes += pruned.bytes
            report.removedPaths.append(contentsOf: pruned.paths)
            report.removedBytes += pruneTranscriptSnapshots()
        }
        if decision.level == .four {
            throw decision.failure ?? HostStorageFailure(
                reason: "host storage is full and no reclaimable data remains",
                remedy: "Free space in the workspace, then retry.",
                budgetedBytes: usage.budgetedBytes,
                workspaceBytes: usage.workspaceLogicalBytes)
        }
        return report
    }

    /// One-time, re-entrant tiering migration for old installs. It copies or
    /// moves only derived data; authoritative stores are never touched.
    @discardableResult
    public func migrateLegacyCachesIfNeeded(fileManager: FileManager = .default) -> [String] {
        var migrated: [String] = []
        try? fileManager.createDirectory(at: paths.cachesRoot,
                                         withIntermediateDirectories: true)
        // Overlay cache: move a valid pair only after both files exist.
        let legacyTar = paths.workspaceRoot.appendingPathComponent("overlay-cache.tar")
        let legacySidecar = paths.workspaceRoot.appendingPathComponent("overlay-cache.json")
        let newTar = paths.cachesRoot.appendingPathComponent("overlay-cache.tar")
        let newSidecar = paths.cachesRoot.appendingPathComponent("overlay-cache.json")
        if fileManager.fileExists(atPath: legacyTar.path),
           fileManager.fileExists(atPath: legacySidecar.path),
           !fileManager.fileExists(atPath: newTar.path),
           !fileManager.fileExists(atPath: newSidecar.path) {
            do {
                try fileManager.moveItem(at: legacyTar, to: newTar)
                try fileManager.moveItem(at: legacySidecar, to: newSidecar)
                migrated.append("overlay-cache")
            } catch {
                // The workspace overlay builder repeats the same migration and
                // rebuilds the cache if only one file survived.
            }
        }
        // Transcript snapshots: copy, then leave the legacy file for rollback.
        let legacyTranscripts = paths.documentsRoot
            .appendingPathComponent("transcript-snapshots", isDirectory: true)
        let newTranscripts = paths.transcriptSnapshotCacheRoot
        if let scopes = try? fileManager.contentsOfDirectory(
            at: legacyTranscripts,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) {
            for scope in scopes {
                let destination = newTranscripts.appendingPathComponent(scope.lastPathComponent,
                                                                       isDirectory: true)
                try? fileManager.createDirectory(at: destination,
                                                 withIntermediateDirectories: true)
                guard let files = try? fileManager.contentsOfDirectory(
                    at: scope,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]) else { continue }
                for file in files where file.pathExtension == "json" {
                    let target = destination.appendingPathComponent(file.lastPathComponent)
                    guard !fileManager.fileExists(atPath: target.path),
                          let data = try? Data(contentsOf: file) else { continue }
                    if (try? data.write(to: target, options: .atomic)) != nil {
                        migrated.append("transcript:\(scope.lastPathComponent)/\(file.lastPathComponent)")
                    }
                }
            }
        }
        return migrated
    }

    private func pruneRebuildableCaches(responseLog: ResponseLog?,
                                        eligibleResponseKeys: Set<String>) async
        -> (bytes: Int, paths: [String]) {
        let fileManager = FileManager.default
        var removedBytes = 0
        var removedPaths: [String] = []
        // Response entries first: the log owns their atomic delete and refuses
        // a resume in flight. We never touch its pending/staging directories.
        if let responseLog, !eligibleResponseKeys.isEmpty {
            let before = scanner.bytes(at: paths.responseLogCacheRoot)
                + scanner.bytes(at: paths.workspaceRoot.appendingPathComponent("response-log",
                                                                               isDirectory: true))
            _ = await responseLog.reclaim(keys: eligibleResponseKeys)
            let after = scanner.bytes(at: paths.responseLogCacheRoot)
                + scanner.bytes(at: paths.workspaceRoot.appendingPathComponent("response-log",
                                                                               isDirectory: true))
            removedBytes += max(0, before - after)
        }
        // Keep the newest boot overlay: the current page may still be reading
        // it. The cache tar itself is disposable; the next boot repacks.
        let overlayKeep = newestBootOverlay(fileManager: fileManager)
        for directory in [paths.cachesRoot, paths.workspaceRoot] {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            for file in files {
                let name = file.lastPathComponent
                let isOverlay = name == "overlay-cache.tar" || name == "overlay-cache.json"
                    || (name.hasPrefix("overlay-") && name.hasSuffix(".tar"))
                guard isOverlay else { continue }
                if name.hasPrefix("overlay-"), name.hasSuffix(".tar"),
                   file.standardizedFileURL == overlayKeep?.standardizedFileURL {
                    continue
                }
                let bytes = scanner.bytes(at: file)
                if (try? fileManager.removeItem(at: file)) != nil {
                    removedBytes += bytes
                    removedPaths.append(name)
                }
            }
        }
        return (removedBytes, removedPaths)
    }

    private func newestBootOverlay(fileManager: FileManager) -> URL? {
        var candidates: [(URL, Date)] = []
        for directory in [paths.cachesRoot, paths.workspaceRoot] {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for file in files {
                let name = file.lastPathComponent
                guard name.hasPrefix("overlay-"), name.hasSuffix(".tar"),
                      name != "overlay-cache.tar" else { continue }
                let modified = (try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                candidates.append((file, modified))
            }
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    private func pruneTranscriptSnapshots() -> Int {
        let fileManager = FileManager.default
        let before = scanner.bytes(at: paths.transcriptSnapshotCacheRoot)
        try? fileManager.removeItem(at: paths.transcriptSnapshotCacheRoot)
        return before
    }
}
