// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: reclaim segment applier.
//
// PLAN §2.5 (D15) and spec/v1/handoff.md §4/§5, wal.md §6/§7/§10.
// The remote returns complete WAL segments covering `(base_mseq, wal_seq]`.
// This applier validates them against the descriptors and the tar hash (already
// checked by the client), applies only mutation records in ascending mseq order
// with the wal.md §6 materialization rules, skips everything at or below the
// local applied mseq, sets `last_mseq = max(last_mseq, fence.wal_seq)` (D17),
// closes an epoch in the D18 order and persists the new manifest so the next
// ``WorkspaceLog`` open starts at `wal_seq + 1`.

import Foundation
import PhoneDSHLog
import PhoneDSHWire

/// Outcome of applying one reclaim response (handoff.md §5).
public struct HandoffApplyResult: Equatable, Sendable {
    /// Highest contiguous applied mseq (must equal `fence.wal_seq`).
    public var appliedMseq: UInt64
    /// Highest mseq ever allocated (D17); the next boot starts at this + 1.
    public var lastMseq: UInt64
    /// The applier ensured a durable epoch covering ``appliedMseq``.
    public var epochClosed: Bool
    public var mutationsApplied: Int
    public var mutationsSkipped: Int

    public init(appliedMseq: UInt64, lastMseq: UInt64, epochClosed: Bool,
                mutationsApplied: Int = 0, mutationsSkipped: Int = 0) {
        self.appliedMseq = appliedMseq
        self.lastMseq = lastMseq
        self.epochClosed = epochClosed
        self.mutationsApplied = mutationsApplied
        self.mutationsSkipped = mutationsSkipped
    }
}

/// Applies the segments returned by `/v1/handoff/reclaim`.
public protocol HandoffSegmentApplying: Sendable {
    func apply(_ download: HandoffReclaimDownload) async throws -> HandoffApplyResult
}

/// Applies a reclaim response to the on-disk workspace of
/// ``PhoneDSHLog/WorkspaceLog``.
///
/// The caller must have quiesced the log (the phone is in `Remote`/`Reclaiming`
/// with admission closed, so no append can race the manifest rewrite). The
/// applier uses only the landed public WAL/recovery types, so no log module
/// patch is needed.
public struct WorkspaceLogSegmentApplier: HandoffSegmentApplying {
    public let root: URL
    public let configuration: WorkspaceLogConfiguration
    public let bootID: Data

    public init(root: URL, configuration: WorkspaceLogConfiguration,
                bootID: Data) throws {
        guard bootID.count == 16 else {
            throw HandoffError.applyFailed("boot_id must be 16 raw bytes")
        }
        self.root = root
        self.configuration = configuration
        self.bootID = bootID
    }

    public func apply(_ download: HandoffReclaimDownload) async throws
        -> HandoffApplyResult {
        try applySynchronously(download)
    }

    // MARK: - Synchronous core

    private func applySynchronously(_ download: HandoffReclaimDownload) throws
        -> HandoffApplyResult {
        let metadata = download.metadata
        try metadata.validate()
        guard UInt64(download.payloadBytes) == metadata.payloadBytes,
              download.payloadSHA256 == metadata.payloadSha256 else {
            throw HandoffError.payloadMismatch("reclaim payload no longer matches its metadata")
        }
        let files: [HandoffSegmentFile]
        do {
            files = try HandoffSegmentArchive.read(from: download.payloadURL)
        } catch let error as HandoffError {
            throw error
        } catch {
            throw HandoffError.payloadMismatch("reclaim segment archive is unreadable")
        }
        let validated = try HandoffSegmentArchive.validate(files: files,
                                                           descriptors: metadata.segments)
        let mutations = try HandoffSegmentArchive.mutationRecords(
            validated, baseMseq: metadata.baseMseq, walSeq: metadata.fence.walSeq)

        let paths = WorkspacePaths(root: root)
        let manifest: Manifest
        do {
            guard let stored = try ManifestStore(paths: paths).read() else {
                throw HandoffError.applyFailed("the phone workspace has no manifest")
            }
            manifest = stored
        } catch let error as HandoffError {
            throw error
        } catch {
            throw HandoffError.applyFailed("the phone workspace manifest is unreadable")
        }
        let scan: WALScan
        do {
            scan = try WALReader.scan(directory: paths.walDirectory)
        } catch {
            throw HandoffError.applyFailed("the phone WAL cannot be scanned")
        }
        let localApplied = manifest.materializedUptoMseq
        let localLast = max(manifest.lastMseq, scan.lastMutationMseq)
        let materializer: Materializer
        do {
            materializer = try Materializer(root: root,
                                            materializedUptoMseq: localApplied)
        } catch {
            throw HandoffError.applyFailed("cannot open the materialized copy")
        }

        // A reclaim can arrive before the phone materialized its own WAL
        // prefix (crash between append and materialize). Catch the local tail
        // up to the snapshot base first; the remote segments then continue it.
        if localApplied < metadata.baseMseq {
            let catchUp = WALReader.records(in: scan.segments,
                                            fromMseq: localApplied + 1)
                .filter { !$0.isEpochClose && $0.mseq <= metadata.baseMseq }
            do {
                _ = try materializer.apply(records: catchUp)
                try materializer.fsyncEpoch()
            } catch {
                throw HandoffError.applyFailed("cannot materialize the local WAL tail")
            }
            guard materializer.materializedUptoMseq == metadata.baseMseq else {
                throw HandoffError.applyFailed(
                    "the local materialized copy cannot reach the snapshot base")
            }
        }

        var applied = 0
        var skipped = 0
        for record in mutations {
            if record.mseq <= materializer.materializedUptoMseq {
                skipped += 1
                continue
            }
            guard record.mseq == materializer.materializedUptoMseq + 1 else {
                throw HandoffError.segmentContinuity(
                    "local materialized watermark \(materializer.materializedUptoMseq) "
                        + "does not continue at \(record.mseq)")
            }
            let outcome: MaterializeOutcome
            do {
                outcome = try materializer.apply(record)
            } catch {
                throw HandoffError.applyFailed(
                    "a reclaimed mutation could not be materialized")
            }
            if case .baseMismatch = outcome {
                throw HandoffError.applyFailed(
                    "a reclaimed appended write needs a VFS_RESYNC")
            }
            applied += 1
        }
        do {
            try materializer.fsyncEpoch()
        } catch {
            throw HandoffError.applyFailed("cannot fsync the reclaimed materialized copy")
        }
        guard materializer.materializedUptoMseq == metadata.fence.walSeq else {
            throw HandoffError.applyFailed(
                "materialized watermark \(materializer.materializedUptoMseq) "
                    + "is not fence.wal_seq \(metadata.fence.walSeq)")
        }

        // Idempotent replay: the previous apply already installed its
        // epoch-close-only segment (`first_mseq = last_mseq + 1`, no mutation,
        // durable = fence.wal_seq) and advanced the manifest. A first reclaim
        // always closes an epoch, even when the remote returned no mutation.
        let closedByPreviousApply = scan.segments.contains { segment in
            segment.mutationCount == 0
                && segment.name.epoch == manifest.lastDurableEpoch
                && segment.header.firstMseq == localLast &+ 1
                && segment.epochClose?.durableUpto == metadata.fence.walSeq
        }
        if applied == 0,
           manifest.materializedUptoMseq == metadata.fence.walSeq,
           localLast >= metadata.fence.walSeq,
           closedByPreviousApply {
            return HandoffApplyResult(appliedMseq: metadata.fence.walSeq,
                                      lastMseq: localLast,
                                      epochClosed: true,
                                      mutationsApplied: 0,
                                      mutationsSkipped: skipped)
        }

        let lastMseq = max(manifest.lastMseq, localLast, metadata.fence.walSeq)
        guard lastMseq < UInt64.max else {
            throw HandoffError.applyFailed("the mseq range is exhausted")
        }
        let highestEpoch = max(manifest.lastDurableEpoch, scan.highestEpoch,
                               manifest.segments.map(\.epoch).max() ?? 0)
        guard highestEpoch < WALSegmentName.maximumEpoch else {
            throw HandoffError.applyFailed("the WAL epoch range is exhausted")
        }
        let newEpoch = highestEpoch + 1
        let segmentName: WALSegmentName
        let header: WALSegmentHeader
        let segment: WALSegment
        do {
            segmentName = try WALSegmentName(epoch: newEpoch, segment: 0)
            header = try WALSegmentHeader(firstMseq: lastMseq + 1, bootID: bootID)
            let close = try WALRecord(
                epochClose: HandoffFile.currentTimeMilliseconds(),
                durableUpto: metadata.fence.walSeq)
            segment = try WALSegment(header: header, records: [close])
        } catch {
            throw HandoffError.applyFailed("cannot encode the reclaim epoch close")
        }
        let segmentURL = segmentName.url(in: paths.walDirectory)
        do {
            try HandoffFile.unlink(segmentURL)
            try HandoffFile.writeAtomically(path: segmentURL) { handle in
                try handle.write(contentsOf: segment.encoded())
            }
            try HandoffFile.fullFsync(segmentURL)
            try HandoffFile.fsyncDirectory(paths.walDirectory)
        } catch let error as HandoffError {
            throw error
        } catch {
            throw HandoffError.applyFailed("cannot write the reclaim epoch-close segment")
        }

        // Keep every present listed segment (recovery truncates droppable ones
        // after the next open); drop a missing listed segment only when D11
        // allows it (all its mutations are at or below the new watermark).
        let onDisk = Dictionary(uniqueKeysWithValues:
            scan.segments.map { ($0.manifestFile, $0) })
        var listed: [ManifestSegment] = []
        for entry in manifest.segments {
            if let present = onDisk[entry.file] {
                guard present.header.firstMseq == entry.firstMseq,
                      present.lastMutationMseq == entry.lastMseq else {
                    throw HandoffError.applyFailed(
                        "the local manifest and WAL disagree")
                }
                listed.append(entry)
            } else if entry.lastMseq <= metadata.fence.walSeq {
                continue
            } else {
                throw HandoffError.applyFailed(
                    "a listed WAL segment above the watermark is missing")
            }
        }
        listed.append(ManifestSegment(file: segmentName.manifestFile,
                                      epoch: newEpoch,
                                      firstMseq: header.firstMseq,
                                      lastMseq: 0))
        let updated = Manifest(bootID: HandoffHex.encode(bootID),
                               materializedUptoMseq: metadata.fence.walSeq,
                               lastMseq: lastMseq,
                               lastDurableEpoch: newEpoch,
                               segments: listed)
        do {
            try ManifestStore(paths: paths).write(updated)
        } catch {
            throw HandoffError.applyFailed("cannot write the reclaimed manifest")
        }
        return HandoffApplyResult(appliedMseq: metadata.fence.walSeq,
                                  lastMseq: lastMseq,
                                  epochClosed: true,
                                  mutationsApplied: applied,
                                  mutationsSkipped: skipped)
    }
}
