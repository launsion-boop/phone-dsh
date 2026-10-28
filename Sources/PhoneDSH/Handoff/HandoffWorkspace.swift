// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: snapshot and segment sources.
//
// PLAN §2.5 (D15) and spec/v1/handoff.md §2–§4. Before the fence CAS
// the phone has closed admission and an epoch; the snapshot then packs the
// materialized copy at `materialized_upto_mseq` as an uncompressed ustar and
// the segments request carries the complete WAL segment files covering
// `(base, wal_seq]`. Nothing here reads or writes `/dsh/tmp`, and no local
// absolute path is ever put in a descriptor.

import Foundation
import PhoneDSHLog
import PhoneDSHWire

/// The two uploads one handoff needs, plus the positions they replicate.
public struct HandoffPreparedUpload: Sendable {
    /// `materialized_upto_mseq` of the snapshot (§3).
    public var baseMseq: UInt64
    /// The epoch-close `durable_upto`; the fence target (§2).
    public var walSeq: UInt64
    /// Uncompressed ustar of `materialized/{home,workspace}`.
    public var snapshotURL: URL
    public var snapshotBytes: Int
    public var snapshotSHA256: String
    /// Ordered descriptors of the segment tar (§4); empty when base == walSeq.
    public var segments: [HandoffSegmentDescriptor]
    public var segmentsURL: URL
    public var segmentsBytes: Int
    public var segmentsSHA256: String
    /// Scratch files the source created; removed by ``HandoffSourceProviding/cleanUp(_:)``.
    public var temporaryFiles: [URL]

    public init(baseMseq: UInt64, walSeq: UInt64,
                snapshotURL: URL, snapshotBytes: Int, snapshotSHA256: String,
                segments: [HandoffSegmentDescriptor],
                segmentsURL: URL, segmentsBytes: Int, segmentsSHA256: String,
                temporaryFiles: [URL]) {
        self.baseMseq = baseMseq
        self.walSeq = walSeq
        self.snapshotURL = snapshotURL
        self.snapshotBytes = snapshotBytes
        self.snapshotSHA256 = snapshotSHA256
        self.segments = segments
        self.segmentsURL = segmentsURL
        self.segmentsBytes = segmentsBytes
        self.segmentsSHA256 = segmentsSHA256
        self.temporaryFiles = temporaryFiles
    }

    /// Structural checks of §3/§4 before any bytes leave the phone.
    public func validate() throws {
        guard baseMseq <= walSeq else {
            throw HandoffError.notQuiescent("snapshot base is above the fence target")
        }
        guard snapshotBytes >= 0,
              snapshotBytes <= HandoffLimits.maximumPayloadBytes else {
            throw HandoffError.payloadTooLarge(bytes: snapshotBytes)
        }
        guard HandoffHex.isLowercaseHex(snapshotSHA256, count: 64) else {
            throw HandoffError.invalidResponse("snapshot sha256 is malformed")
        }
        guard segmentsBytes >= 0,
              segmentsBytes <= HandoffLimits.maximumPayloadBytes else {
            throw HandoffError.payloadTooLarge(bytes: segmentsBytes)
        }
        guard HandoffHex.isLowercaseHex(segmentsSHA256, count: 64) else {
            throw HandoffError.invalidResponse("segments sha256 is malformed")
        }
        for descriptor in segments { try descriptor.validate() }
    }
}

/// Where ``HandoffCoordinator`` gets the snapshot and segments.
public protocol HandoffSourceProviding: Sendable {
    /// Closes an epoch (when the implementation owns a live log) and returns
    /// the two payloads at the same replication position.
    func prepareHandoff() async throws -> HandoffPreparedUpload
    /// Removes the scratch files of ``prepareHandoff()``.
    func cleanUp(_ upload: HandoffPreparedUpload) async
}

/// Packs a quiesced workspace directory. The caller must have closed admission
/// and an epoch; this type never mutates the WAL or the materialized copy.
public struct HandoffWorkspaceSnapshotter: HandoffSourceProviding {
    public let root: URL
    public let configuration: WorkspaceLogConfiguration
    public let scratchDirectory: URL

    /// - Parameters:
    ///   - root: `Library/xl/<workspace_id>/`.
    ///   - configuration: WAL configuration of that workspace.
    ///   - scratchDirectory: Directory for the two temporary payloads. The
    ///     caller owns it and ``cleanUp(_:)`` removes only the files it created.
    public init(root: URL, configuration: WorkspaceLogConfiguration,
                scratchDirectory: URL? = nil) {
        self.root = root
        self.configuration = configuration
        self.scratchDirectory = scratchDirectory
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("pdsh-handoff-scratch-\(UUID().uuidString)")
    }

    public func prepareHandoff() async throws -> HandoffPreparedUpload {
        try prepareHandoffSynchronously()
    }

    public func cleanUp(_ upload: HandoffPreparedUpload) async {
        for url in upload.temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Synchronous core

    private func prepareHandoffSynchronously() throws -> HandoffPreparedUpload {
        let paths = WorkspacePaths(root: root)
        let manifest: Manifest
        do {
            guard let stored = try ManifestStore(paths: paths).read() else {
                throw HandoffError.notQuiescent("the workspace has no manifest")
            }
            manifest = stored
        } catch let error as HandoffError {
            throw error
        } catch {
            throw HandoffError.notQuiescent("the workspace manifest is unreadable")
        }
        let scan: WALScan
        do {
            scan = try WALReader.scan(directory: paths.walDirectory)
        } catch {
            throw HandoffError.notQuiescent("the WAL cannot be scanned")
        }
        let tail = max(manifest.lastMseq, scan.lastMutationMseq)
        if tail > 0, scan.durableMseq < tail {
            throw HandoffError.notQuiescent(
                "the epoch close does not cover the WAL tail")
        }
        let walSeq = tail
        let base = manifest.materializedUptoMseq
        guard base <= walSeq else {
            throw HandoffError.notQuiescent("materialized watermark is above the WAL tail")
        }
        try HandoffFile.ensureDirectory(scratchDirectory)
        let snapshotURL = scratchDirectory
            .appendingPathComponent("snapshot-\(UUID().uuidString).tar")
        let segmentsURL = scratchDirectory
            .appendingPathComponent("segments-\(UUID().uuidString).tar")
        let temporaryFiles = [snapshotURL, segmentsURL]
        do {
            // D21 compresses only the boot overlay; the D15 snapshot stays an
            // uncompressed ustar for the remote applier.
            let packer = OverlayPacker(materializedDirectory: paths.materializedDirectory)
            let packed = try packer.packUncompressed(to: snapshotURL)
            guard packed.byteCount <= HandoffLimits.maximumPayloadBytes else {
                throw HandoffError.payloadTooLarge(bytes: packed.byteCount)
            }
            let snapshotSHA = try SHA256.hashFile(snapshotURL)

            let selected = try HandoffSegmentPlanner.select(segments: scan.segments,
                                                            baseMseq: base,
                                                            walSeq: walSeq)
            var files: [HandoffSegmentFile] = []
            for segment in selected {
                let bytes: Data
                do {
                    bytes = try Data(contentsOf: segment.url, options: [.mappedIfSafe])
                } catch {
                    throw HandoffError.badRequest("a WAL segment file is unreadable")
                }
                files.append(try HandoffSegmentFile(file: "wal/" + segment.name.fileName,
                                                    bytes: bytes))
            }
            let segmentsBytes = try HandoffSegmentWriter.writeArchive(files,
                                                                      to: segmentsURL)
            guard segmentsBytes <= HandoffLimits.maximumPayloadBytes else {
                throw HandoffError.payloadTooLarge(bytes: segmentsBytes)
            }
            let segmentsSHA = try SHA256.hashFile(segmentsURL)
            let descriptors = try files.map { try $0.descriptor() }
            let upload = HandoffPreparedUpload(
                baseMseq: base,
                walSeq: walSeq,
                snapshotURL: snapshotURL,
                snapshotBytes: packed.byteCount,
                snapshotSHA256: snapshotSHA,
                segments: descriptors,
                segmentsURL: segmentsURL,
                segmentsBytes: segmentsBytes,
                segmentsSHA256: segmentsSHA,
                temporaryFiles: temporaryFiles)
            try upload.validate()
            return upload
        } catch {
            for url in temporaryFiles {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }
}

/// Converts a live ``WorkspaceLog`` into the two payloads: it closes one epoch
/// in the D18 order (the §2 precondition) and then packs the quiesced
/// directory. The caller must already have closed admission.
public actor WorkspaceLogHandoffSource: HandoffSourceProviding {
    private let log: WorkspaceLog
    private let scratchDirectory: URL

    public init(log: WorkspaceLog, scratchDirectory: URL? = nil) {
        self.log = log
        self.scratchDirectory = scratchDirectory
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("pdsh-handoff-scratch-\(UUID().uuidString)")
    }

    public func prepareHandoff() async throws -> HandoffPreparedUpload {
        let ack: WorkspaceLogAck
        do {
            // One close may be raced by a sink frame that the drain could not
            // see (the channel is still live here); keep closing until the
            // level-2 watermark covers the effective WAL tail. The snapshotter
            // below re-checks the on-disk close record and refuses a tail it
            // does not cover.
            ack = try await log.closeEpochCoveringTail()
        } catch {
            throw HandoffError.notQuiescent("the workspace epoch could not be closed")
        }
        let positions = await log.positions()
        guard positions.ackedMseq <= ack.uptoMseq else {
            throw HandoffError.notQuiescent(
                "a mutation was accepted after the epoch close")
        }
        let workspacePaths = await log.paths
        let workspaceConfiguration = await log.configuration
        let snapshotter = HandoffWorkspaceSnapshotter(
            root: workspacePaths.root,
            configuration: workspaceConfiguration,
            scratchDirectory: scratchDirectory)
        return try await snapshotter.prepareHandoff()
    }

    public func cleanUp(_ upload: HandoffPreparedUpload) async {
        for url in upload.temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Segment selection

/// Selects the complete WAL segment files of §4 for `(base, walSeq]`.
public enum HandoffSegmentPlanner {
    /// A segment is selected when it carries a mutation above `baseMseq`; the
    /// first such segment may begin at or below the base (a straddling
    /// segment), which the remote replays idempotently. The union of the
    /// selected mutation mseqs must be exactly `base + 1 ... walSeq`.
    public static func select(segments: [WALSegmentFile],
                              baseMseq: UInt64,
                              walSeq: UInt64) throws -> [WALSegmentFile] {
        var expected = baseMseq + 1
        var selected: [WALSegmentFile] = []
        for segment in segments.sorted(by: { $0.name < $1.name }) {
            let mutations = segment.records.filter { !$0.isEpochClose }
            guard !mutations.isEmpty else { continue }
            guard let last = mutations.map(\.mseq).max() else { continue }
            guard last <= walSeq else {
                throw HandoffError.segmentContinuity(
                    "segment \(segment.fileName) has mseq \(last) above wal_seq \(walSeq)")
            }
            let inRange = mutations.filter { $0.mseq > baseMseq }
            guard let first = inRange.first?.mseq else { continue }
            guard first == expected else {
                throw HandoffError.segmentContinuity(
                    "segment \(segment.fileName) starts at \(first), expected \(expected)")
            }
            selected.append(segment)
            expected = last + 1
        }
        guard expected == walSeq + 1 else {
            throw HandoffError.segmentContinuity(
                "WAL segments do not cover (\(baseMseq), \(walSeq)]")
        }
        return selected
    }
}
