// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: cold recovery and reconcile.
//
// PLAN §2.3 (D11/D17/D19) and spec/v1/wal.md §7.2, §10. On open the
// manager reads the manifest, scans every segment (the manifest list serves
// truncation only), replays the WAL tail into the materialized copy, drops
// durable segments that are fully applied, detects a boot identity change and
// reports the HELLO positions. `reconcile(snapshot:)` is the full-tree check
// used only when the manifest and the WAL tail disagree.

import Darwin
import Foundation
import PhoneDSHWire

/// One caller-supplied `(path, size, sha256)` entry of a full-tree snapshot.
public struct SnapshotEntry: Equatable, Sendable {
    /// Absolute VFS path under `/dsh/home` or `/dsh/workspace`.
    public var path: String
    public var size: Int
    /// Lowercase hex SHA-256.
    public var sha256: String

    public init(path: String, size: Int, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// Kind of one reconcile difference.
public enum ReconcileDifferenceKind: String, Equatable, Sendable {
    /// The snapshot names the path but the materialized copy does not have it.
    case missingOnDisk
    /// Size differs.
    case sizeMismatch
    /// Size matches but the digest differs.
    case digestMismatch
    /// The materialized copy has the path but the snapshot does not.
    case missingInSnapshot
    /// The snapshot names a directory where a file was expected (or the
    /// reverse); the snapshot carries regular files only.
    case typeMismatch
}

/// One difference between the caller snapshot and the materialized tree.
public struct ReconcileDifference: Equatable, Sendable {
    public var path: String
    public var kind: ReconcileDifferenceKind
    public var expectedSize: Int?
    public var actualSize: Int?

    public init(path: String, kind: ReconcileDifferenceKind,
                expectedSize: Int? = nil, actualSize: Int? = nil) {
        self.path = path
        self.kind = kind
        self.expectedSize = expectedSize
        self.actualSize = actualSize
    }
}

/// Cold recovery and reconcile of one workspace (wal.md §7.2, §10).
public struct RecoveryManager: Sendable {
    public let configuration: WorkspaceLogConfiguration
    public let bootID: Data
    public let paths: WorkspacePaths

    public init(configuration: WorkspaceLogConfiguration, bootID: Data) {
        self.configuration = configuration
        self.bootID = bootID
        self.paths = WorkspacePaths(root: configuration.root)
    }

    private var bootIDHex: String {
        bootID.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Recovery

    /// Runs the cold-recovery pass and returns the HELLO positions.
    ///
    /// Order (wal.md §7.2, §10, D11/D18):
    ///   1. read and validate the manifest, then scan the real `wal/` directory
    ///      (the manifest list serves truncation only, never as the WAL view);
    ///   2. classify every segment against the manifest and the acknowledged
    ///      tail; a segment with real records is never unlinked on the strength
    ///      of an inverted manifest — it is retained and verified;
    ///   3. require the retained WAL, above the materialized watermark, to be
    ///      strictly contiguous (D8/D17): a hole fails loud instead of leaving
    ///      acknowledged mutations silently unapplied;
    ///   4. replay the tail (or the staged reconcile) into the materialized
    ///      copy;
    ///   5. run the materialized-copy invariant and repair it from the WAL when
    ///      the retained history starts at mseq 1, before deleting one segment;
    ///   6. write the manifest, then unlink only segments whose epoch closed in
    ///      the D18 order and whose every mutation is at or below the verified
    ///      watermark.
    public func recover() throws -> RecoveryReport {
        guard bootID.count == 16 else {
            throw LogError.corrupt("boot_id must be 16 raw bytes")
        }
        // Restore/remove the materialized tree's crash leftovers before
        // `createDirectories` can make an absent `materialized/` look present
        // (which would strand the only copy under `.materialized.previous`).
        try MaterializedInvariant.sweepStartupLeftovers(paths: paths)
        try paths.createDirectories()
        let manifestStore = ManifestStore(paths: paths)

        // wal.md §7.2: a missing, unreadable or schema-invalid manifest follows
        // the missing-manifest rule. A manifest that *decodes* but whose
        // contents are impossible is different: that is `WAL_CORRUPT` and must
        // fail loud instead of being rebuilt as if the checkpoint were absent.
        var manifest: Manifest?
        do {
            manifest = try manifestStore.read()
        } catch {
            manifest = nil
        }
        if let manifest {
            try WALSegmentLifecycle.validate(manifest)
        }

        // Torn tails are truncated by the scan itself (D19) before anything is
        // classified; the returned scan already reflects the truncation.
        let scan = try WALReader.scan(directory: paths.walDirectory, truncateTornTail: true)
        let markerPresent = LogFile.exists(paths.reconcileMarkerURL)

        guard let manifest else {
            return try recoverWithoutManifest(scan: scan, manifestStore: manifestStore,
                                              markerPresent: markerPresent)
        }

        try rejectDuplicateMutationMseqs(scan)

        let onDisk = Dictionary(uniqueKeysWithValues: scan.segments.map { ($0.manifestFile, $0) })
        let listedFiles = Set(manifest.segments.map(\.file))
        let newestSegmentName = scan.segments.last?.name
        let watermark = manifest.materializedUptoMseq
        let listedMutationMax = manifest.segments.map(\.lastMseq).max() ?? 0
        var attestedTail = max(manifest.lastMseq, listedMutationMax, watermark)
        var retained: [WALSegmentFile] = []
        var droppedNames: [String] = []
        var needsVerification = markerPresent

        // Listed segments: verify the recorded range against the real file.
        for listed in manifest.segments.sorted(by: Self.segmentOrder) {
            if let segment = onDisk[listed.file] {
                try WALSegmentLifecycle.validateListedRange(
                    listed,
                    segment: segment,
                    materializedUptoMseq: watermark,
                    isNewest: segment.name == newestSegmentName,
                    tornTailTruncated: scan.truncatedTornTail)
                retained.append(segment)
                attestedTail = max(attestedTail, segment.lastMutationMseq)
                if segment.lastMutationMseq != listed.lastMseq {
                    // The manifest lags real records (a crash before the next
                    // rewrite). Recovery adopts the difference, so verify.
                    needsVerification = true
                }
            } else if listed.lastMseq <= watermark {
                // Listed and missing below the watermark: drop silently (D11).
                droppedNames.append(listed.file)
            } else {
                throw LogError.corrupt("listed segment \(listed.file) is missing above the watermark")
            }
        }

        // Unlisted segments: never trust the manifest as the WAL view.
        for segment in scan.segments where !listedFiles.contains(segment.manifestFile) {
            let hasTail = segment.lastMutationMseq > watermark
            if hasTail {
                // The open epoch's segment is unlisted after a crash before the
                // next manifest write; it may start at or before the attested
                // tail (the overlap is replayed idempotently) but never after a
                // hole in the mseq sequence.
                guard let firstMutation = segment.firstMutationMseq,
                      firstMutation <= attestedTail + 1 else {
                    throw LogError.corrupt("adopted WAL tail \(segment.fileName) is not contiguous")
                }
                retained.append(segment)
                attestedTail = max(attestedTail, segment.lastMutationMseq)
                needsVerification = true
            } else if segment.hasEpochClose && segment.epoch > manifest.lastDurableEpoch {
                // A newer epoch close repairs the durable point; retain it (D11).
                retained.append(segment)
            } else if segment.records.isEmpty {
                // Header-only: the eager tail segment of a previous boot holds
                // no mutation and no close record. It is not content, so it can
                // never be the only copy of an acknowledged write.
                droppedNames.append(segment.manifestFile)
            } else {
                // Real acknowledged history that a stale/inverted manifest did
                // not list. It is at or below the watermark, so the
                // materialized copy is its witness: retain it and verify the
                // copy. Unlinking here is what silently lost the G2-A09 class.
                retained.append(segment)
                needsVerification = true
            }
        }

        retained.sort { $0.name < $1.name }
        let retainedRecords = retained.flatMap(\.records)
        let lastMutation = retained.compactMap(\.lastMutationMseq).max() ?? 0
        let lastMseq = max(manifest.lastMseq, lastMutation, scan.lastMutationMseq, watermark)
        let tail = try validatedTail(retained: retained, watermark: watermark,
                                     lastMseq: lastMseq)

        // Replay the tail (or redo the staged reconcile) into the copy.
        var resyncPaths: Set<String> = []
        var replayedRecords = 0
        var reconciled = false
        var localRepairs: [MaterializedInvariantLocalRepair] = []
        var currentWatermark = watermark
        if markerPresent {
            // A crash can leave the copy under the repair's previous name or
            // absent entirely; restore before staged reconcile reads the base.
            _ = MaterializedInvariant.restorePreviousTreeIfNeeded(paths: paths)
            let report = try stagedReconcile(watermark: watermark, records: tail)
            currentWatermark = report.materializedUptoMseq
            resyncPaths.formUnion(report.baseMismatchPaths)
            replayedRecords = report.applied + report.skipped
            reconciled = true
        } else {
            let materializer = try Materializer(root: configuration.root,
                                                materializedUptoMseq: watermark)
            let report = try materializer.apply(records: tail)
            try materializer.fsyncEpoch()
            currentWatermark = report.materializedUptoMseq
            resyncPaths.formUnion(materializer.needsResyncPaths)
            replayedRecords = report.applied + report.skipped
        }
        if currentWatermark < lastMseq && resyncPaths.isEmpty {
            throw LogError.corrupt(
                "the materialized watermark \(currentWatermark) is below the WAL tail \(lastMseq) without a pending VFS_RESYNC")
        }

        // A checkpoint is worthless if the copy it describes is wrong: verify
        // (and if necessary rebuild from the WAL) before any segment can be
        // unlinked. A clean park exit has no adopted or unclosed epoch, so it
        // skips the extra pass.
        let durableEpochs = WALSegmentLifecycle.durableEpochs(
            of: retained.map { WALSegmentLifecycleRecord(segment: $0) })
        let hasUnclosedHistory = retained.contains { segment in
            !segment.records.isEmpty && !durableEpochs.contains(segment.epoch)
        }
        // Fast path: every retained record is at or below a fsynced
        // materialized watermark and belongs to a durable epoch. The tree is
        // then the checkpoint the verification would re-prove, and a full
        // scan cannot repair anything below the watermark anyway (there is no
        // un-materialized base). The boot after a force-kill used to spend
        // ~18 s scanning hundreds of MB for exactly this case.
        let fullyMaterialized = currentWatermark >= lastMseq
        let checkpointProven = fullyMaterialized && !hasUnclosedHistory
            && resyncPaths.isEmpty
        if (needsVerification || hasUnclosedHistory || !resyncPaths.isEmpty)
            && !checkpointProven {
            let report = try MaterializedInvariant.checkAndRepair(
                paths: paths,
                records: retainedRecords,
                materializedUptoMseq: currentWatermark,
                allowRepair: true,
                bootIDHex: bootIDHex)
            if report.repaired {
                currentWatermark = report.materializedUptoMseq
                // The rebuild replayed every retained record, so the old
                // deferred repairs are settled.
                resyncPaths.removeAll()
            }
            localRepairs = report.localRepairs
        }

        // Positions. `last_mseq` never decreases (D17); the next epoch is above
        // every epoch that existed on disk when recovery started.
        let lastDurableEpoch = max(manifest.lastDurableEpoch,
                                   retained.filter(\.hasEpochClose).map(\.epoch).max() ?? 0)
        let durableMseq = retained.compactMap { $0.epochClose?.durableUpto }.max() ?? 0
        let nextEpoch = max(lastDurableEpoch, scan.highestEpoch,
                            retained.map(\.epoch).max() ?? 0) + 1
        // Truncation (D18/D11): a segment is droppable only when its epoch
        // closed in the D18 order, every mutation is at or below the verifiable
        // watermark and it is not the newest epoch-close segment. The rule is
        // shared with the live writer so the two can never disagree.
        let newestClose = WALSegmentLifecycle.newestEpochClose(
            retained.map { WALSegmentLifecycleRecord(segment: $0) })
        var finalSegments: [WALSegmentFile] = []
        for segment in retained {
            let record = WALSegmentLifecycleRecord(segment: segment)
            let droppable = WALSegmentLifecycle.isDroppable(
                record,
                materializedUptoMseq: currentWatermark,
                durableEpochs: durableEpochs,
                newestEpochClose: newestClose,
                isCurrent: false)
            if droppable {
                droppedNames.append(segment.manifestFile)
            } else {
                finalSegments.append(segment)
            }
        }

        let updated = Manifest(bootID: bootIDHex,
                               materializedUptoMseq: currentWatermark,
                               lastMseq: lastMseq,
                               lastDurableEpoch: lastDurableEpoch,
                               segments: WALSegmentLifecycle.manifestSegments(
                                   finalSegments.map { WALSegmentLifecycleRecord(segment: $0) }))
        try WALSegmentLifecycle.assertConsistent(updated, knownLastMseq: lastMseq)
        try manifestStore.write(updated)
        for name in droppedNames {
            if let name = WALSegmentName(fileName: URL(fileURLWithPath: name).lastPathComponent) {
                try LogFile.unlink(name.url(in: paths.walDirectory))
            }
        }
        try LogFile.fsyncDirectory(paths.walDirectory)
        if markerPresent {
            try LogFile.unlink(paths.reconcileMarkerURL)
            try LogFile.fsyncDirectory(configuration.root)
        }

        return RecoveryReport(
            materializedUptoMseq: currentWatermark,
            nextMseq: lastMseq + 1,
            durableMseq: durableMseq,
            lastDurableEpoch: lastDurableEpoch,
            truncatedTornTail: scan.truncatedTornTail,
            ackedMseq: lastMseq,
            nextEpoch: nextEpoch,
            replayedRecords: replayedRecords,
            droppedSegments: droppedNames,
            needsResync: resyncPaths.sorted(),
            coldRecovery: manifest.bootID != bootIDHex,
            reconciled: reconciled,
            localRepairs: localRepairs)
    }

    // MARK: - Missing manifest (wal.md §7.2)

    private func recoverWithoutManifest(scan: WALScan,
                                        manifestStore: ManifestStore,
                                        markerPresent: Bool) throws -> RecoveryReport {
        let materializedHasContent = try treeHasContent(paths.materializedDirectory)

        if scan.segments.isEmpty {
            // wal.md §7.2 calls a workspace with no manifest and no WAL "new".
            // That is only true when there is no materialized state either: a
            // copy that holds applied files is the last durable state, and
            // deleting it would be silent data loss (the defect class this
            // file exists for). Fail loud and leave the copy untouched.
            guard !materializedHasContent else {
                throw LogError.corrupt(
                    "manifest.json is missing while the materialized copy holds applied state; "
                        + "refusing to treat the workspace as new")
            }
            try LogFile.removeTree(paths.materializedDirectory)
            try paths.createDirectories()
            let materializer = try Materializer(root: configuration.root)
            let manifest = Manifest(bootID: bootIDHex,
                                    materializedUptoMseq: 0,
                                    lastMseq: 0,
                                    lastDurableEpoch: 0,
                                    segments: [])
            try manifestStore.write(manifest)
            if markerPresent {
                try? LogFile.unlink(paths.reconcileMarkerURL)
            }
            return RecoveryReport(materializedUptoMseq: materializer.materializedUptoMseq,
                                  nextMseq: 1,
                                  durableMseq: 0,
                                  lastDurableEpoch: 0,
                                  truncatedTornTail: scan.truncatedTornTail,
                                  ackedMseq: 0,
                                  nextEpoch: 1,
                                  replayedRecords: 0,
                                  droppedSegments: [],
                                  needsResync: [],
                                  coldRecovery: false,
                                  reconciled: false)
        }

        // Validate the coverage BEFORE touching the materialized copy. A
        // truncated history cannot be replayed from mseq 1, so the copy is the
        // authority and must survive the failed recovery untouched.
        guard let earliest = scan.segments.min(by: { $0.name < $1.name }),
              earliest.header.firstMseq == 1 else {
            throw LogError.corrupt(
                "manifest is missing and the earliest segment does not start at mseq 1; "
                    + "the materialized copy is preserved")
        }
        _ = MaterializedInvariant.restorePreviousTreeIfNeeded(paths: paths)

        // Rebuild from the WAL into the staging tree, then exchange: the
        // previous copy is never deleted before the rebuilt tree is in place.
        let staging = paths.stagingDirectory
        try LogFile.removeTree(staging)
        let materializer = try Materializer(root: configuration.root,
                                            materializedUptoMseq: 0,
                                            materializedDirectoryURL: staging)
        let replay = try materializer.apply(records: scan.allRecords)
        try materializer.fsyncEpoch()

        let marker = paths.reconcileMarkerURL
        let payload = "{\"target_tail\":\(scan.lastMutationMseq),"
            + "\"materialized\":\(materializer.materializedUptoMseq),"
            + "\"reason\":\"missing-manifest\"}\n"
        try LogFile.atomicWrite(Data(payload.utf8), to: marker)
        try MaterializedInvariant.swapStagingIntoPlace(paths: paths, staging: staging)

        let lastMseq = scan.lastMutationMseq
        let segments = WALSegmentLifecycle.manifestSegments(scan.segments.map {
            WALSegmentLifecycleRecord(segment: $0)
        })
        let manifest = Manifest(bootID: bootIDHex,
                                materializedUptoMseq: materializer.materializedUptoMseq,
                                lastMseq: lastMseq,
                                lastDurableEpoch: scan.lastDurableEpoch,
                                segments: segments)
        try manifestStore.write(manifest)
        // The marker goes away only after the manifest names the rebuilt tree
        // (D11): a crash before this point makes the next boot redo the rebuild.
        try LogFile.unlink(marker)
        try LogFile.fsyncDirectory(configuration.root)
        return RecoveryReport(
            materializedUptoMseq: materializer.materializedUptoMseq,
            nextMseq: lastMseq + 1,
            durableMseq: scan.durableMseq,
            lastDurableEpoch: scan.lastDurableEpoch,
            truncatedTornTail: scan.truncatedTornTail,
            ackedMseq: lastMseq,
            nextEpoch: max(scan.lastDurableEpoch, scan.highestEpoch) + 1,
            replayedRecords: replay.applied + replay.skipped,
            droppedSegments: [],
            needsResync: Array(materializer.needsResyncPaths).sorted(),
            coldRecovery: true,
            reconciled: false)
    }

    // MARK: - Staged reconcile (wal.md §7.2)

    private func stagedReconcile(watermark: UInt64,
                                 records: [WALRecord]) throws -> MaterializeBatchReport {
        try writeReconcileMarker(targetTail: records.last?.mseq ?? watermark,
                                 materialized: watermark)
        // A crash during a previous exchange can leave the copy under the
        // repair's previous name; restore it before it is used as the base.
        _ = MaterializedInvariant.restorePreviousTreeIfNeeded(paths: paths)
        let staging = paths.stagingDirectory
        try LogFile.removeTree(staging)
        if LogFile.exists(paths.materializedDirectory) {
            try LogFile.copyTree(paths.materializedDirectory, to: staging)
        } else {
            // The materialized base is gone. D11 says the reconcile inputs are
            // the materialized copy plus the WAL tail — never the WAL alone —
            // so a WAL-only base is only legal when the retained history starts
            // at mseq 1 (the missing-manifest condition). Otherwise fail loud
            // and leave the marker for the next boot.
            let scan = try WALReader.scan(directory: paths.walDirectory)
            guard let earliest = scan.segments.min(by: { $0.name < $1.name }),
                  earliest.header.firstMseq == 1 else {
                throw LogError.corrupt(
                    "staged reconcile has no materialized base and the retained WAL does not start at mseq 1")
            }
            let base = try Materializer(root: configuration.root,
                                        materializedUptoMseq: 0,
                                        materializedDirectoryURL: staging)
            _ = try base.apply(records: scan.allRecords.filter { $0.mseq <= watermark })
            try base.fsyncEpoch()
        }
        let stagingMaterializer = try Materializer(root: configuration.root,
                                                   materializedUptoMseq: watermark,
                                                   materializedDirectoryURL: staging)
        let report = try stagingMaterializer.apply(records: records)
        try stagingMaterializer.fsyncEpoch()

        // The same crash-safe exchange the invariant repair uses: the marker
        // written above plus `.materialized.previous` let a boot that crashes
        // between the renames restore the old copy instead of misreading an
        // absent tree as a fresh workspace.
        try MaterializedInvariant.swapStagingIntoPlace(paths: paths, staging: staging)
        return report
    }

    private func writeReconcileMarker(targetTail: UInt64, materialized: UInt64) throws {
        let payload = "{\"boot_id\":\"\(bootIDHex)\",\"target_tail\":\(targetTail),"
            + "\"materialized\":\(materialized)}\n"
        try LogFile.atomicWrite(Data(payload.utf8), to: paths.reconcileMarkerURL)
    }

    // MARK: - Classification helpers

    private static func segmentOrder(_ lhs: ManifestSegment,
                                     _ rhs: ManifestSegment) -> Bool {
        if lhs.epoch != rhs.epoch { return lhs.epoch < rhs.epoch }
        if lhs.file != rhs.file { return lhs.file < rhs.file }
        return lhs.lastMseq < rhs.lastMseq
    }

    private func rejectDuplicateMutationMseqs(_ scan: WALScan) throws {
        var seen = Set<UInt64>()
        for segment in scan.segments {
            for record in segment.records where !record.isEpochClose {
                guard seen.insert(record.mseq).inserted else {
                    throw LogError.corrupt("mseq \(record.mseq) appears in more than one WAL record")
                }
            }
        }
    }

    /// The replay window must be strictly contiguous above the watermark
    /// (D8/D17). A hole means an acknowledged mutation is unrecoverable, so it
    /// fails loud instead of leaving the watermark silently short.
    private func validatedTail(retained: [WALSegmentFile],
                               watermark: UInt64,
                               lastMseq: UInt64) throws -> [WALRecord] {
        let mutations = retained
            .flatMap { $0.records.filter { !$0.isEpochClose } }
            .sorted { $0.mseq < $1.mseq }
        guard lastMseq > watermark else { return [] }
        guard let first = mutations.first(where: { $0.mseq > watermark }) else {
            throw LogError.corrupt(
                "the WAL tail \(lastMseq) is above the materialized watermark \(watermark) but no retained record covers it")
        }
        guard first.mseq == watermark + 1 else {
            throw LogError.corrupt(
                "the retained WAL jumps from the materialized watermark \(watermark) to mseq \(first.mseq)")
        }
        var previous = watermark
        for record in mutations where record.mseq > watermark {
            guard record.mseq == previous + 1 else {
                throw LogError.corrupt(
                    "the retained WAL has a hole between mseq \(previous) and \(record.mseq)")
            }
            previous = record.mseq
        }
        guard previous == lastMseq else {
            throw LogError.corrupt(
                "the retained WAL ends at mseq \(previous), below the acknowledged tail \(lastMseq)")
        }
        return mutations.filter { $0.mseq > watermark }
    }

    /// Whether the materialized copy holds any regular file. Used to decide
    /// whether "no manifest and no WAL" is a brand-new workspace or the loss of
    /// the copy's last durable state.
    private func treeHasContent(_ root: URL) throws -> Bool {
        guard LogFile.exists(root) else { return false }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: []) else {
            return false
        }
        while let element = enumerator.nextObject() {
            guard let nsURL = element as? NSURL else { continue }
            let values = try? (nsURL as URL).resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { return true }
        }
        return false
    }

    // MARK: - Reconcile snapshot

    /// Compares a caller-supplied `(path, size, sha256)` list with the
    /// materialized tree and returns the differences. It never edits either
    /// side; recovery is the only writer of the materialized copy.
    public func reconcile(snapshot: [SnapshotEntry]) throws -> [ReconcileDifference] {
        let materializer = try Materializer(root: configuration.root)
        let onDisk = try materializedFiles(under: materializer.materializedDirectory)
        var expected: [String: SnapshotEntry] = [:]
        for entry in snapshot {
            expected[entry.path] = entry
        }
        var differences: [ReconcileDifference] = []
        var seen = Set<String>()
        for entry in onDisk {
            seen.insert(entry.path)
            guard let wanted = expected[entry.path] else {
                differences.append(ReconcileDifference(path: entry.path,
                                                       kind: .missingInSnapshot,
                                                       actualSize: entry.size))
                continue
            }
            if wanted.size != entry.size {
                differences.append(ReconcileDifference(path: entry.path,
                                                       kind: .sizeMismatch,
                                                       expectedSize: wanted.size,
                                                       actualSize: entry.size))
                continue
            }
            let digest = try SHA256.hashFile(entry.url)
            if digest != wanted.sha256.lowercased() {
                differences.append(ReconcileDifference(path: entry.path,
                                                       kind: .digestMismatch,
                                                       expectedSize: wanted.size,
                                                       actualSize: entry.size))
            }
        }
        for entry in snapshot where !seen.contains(entry.path) {
            let kind: ReconcileDifferenceKind
            if let url = vfsURL(for: entry.path, materializedRoot: materializer.materializedDirectory),
               LogFile.exists(url), (try? LogFile.isDirectory(url)) == true {
                kind = .typeMismatch
            } else {
                kind = .missingOnDisk
            }
            differences.append(ReconcileDifference(path: entry.path,
                                                   kind: kind,
                                                   expectedSize: entry.size))
        }
        return differences.sorted { $0.path < $1.path }
    }

    private struct DiskEntry {
        var path: String
        var size: Int
        var url: URL
    }

    private func materializedFiles(under root: URL) throws -> [DiskEntry] {
        var result: [DiskEntry] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }) else {
            return []
        }
        let base = LogFile.canonicalPath(root)
        while let element = enumerator.nextObject() {
            // The enumerator hands out NSURL on Darwin; bridge explicitly.
            guard let nsURL = element as? NSURL else { continue }
            let url = nsURL as URL
            // macOS reports temporary paths below `/var` through enumerators as
            // `/private/var`; compare canonical paths.
            let path = LogFile.canonicalPath(url)
            let relative: String
            if path.hasPrefix(base + "/") {
                relative = String(path.dropFirst(base.count + 1))
            } else {
                continue
            }
            guard relative.hasPrefix("home/") || relative.hasPrefix("workspace/") else {
                continue
            }
            let trimmed = relative
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                let vfsPath = "/dsh/" + trimmed
                result.append(DiskEntry(path: vfsPath, size: 0, url: url))
                continue
            }
            result.append(DiskEntry(path: "/dsh/" + trimmed,
                                    size: values.fileSize ?? 0,
                                    url: url))
        }
        return result
    }

    private func vfsURL(for path: String, materializedRoot: URL) -> URL? {
        guard path.hasPrefix("/dsh/home/") || path.hasPrefix("/dsh/workspace/") else {
            return nil
        }
        let relative = String(path.dropFirst("/dsh/".count))
        return materializedRoot.appendingPathComponent(relative)
    }

}
