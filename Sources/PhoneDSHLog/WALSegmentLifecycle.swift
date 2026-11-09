// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: the single owner of the WAL
// segment lifecycle.
//
// PLAN §2.3 (D7/D8/D11/D17/D18) and spec/v1/wal.md §1, §4, §7.2, §9.
// The defect this file exists for (G2-A09): the writer, the recovery scan and
// the manifest each had their own idea of which segments exist and what their
// `[first_mseq, last_mseq]` range is. An abort that never reached the epoch
// close left a manifest whose `last_mseq` had advanced past a segment list that
// still described the previous (empty) epoch; the next recovery then classified
// the real, unclosed but acknowledged segments as stale and unlinked them.
//
// Every lifecycle decision now goes through this one enum:
//
//   * which segments the manifest lists (every segment that holds at least one
//     record — a mutation or an epoch-close record; a header-only segment is
//     not content and is not listed);
//   * whether an epoch is durable (the manifest's `last_durable_epoch` plus
//     its `segments[]` list; a retained close record is only the newest-close
//     backstop, not a second requirement);
//   * whether a segment is droppable (it is listed in the manifest, its epoch
//     is at or below `last_durable_epoch`, every mutation in its own records is
//     at or below the materialized watermark, it is not the current open
//     segment and it is not the segment that carries the newest epoch close);
//   * whether the manifest is internally well formed.
//
// Recovery and the live writer both call these functions; they cannot drift.

import Foundation
import PhoneDSHWire

/// One segment's lifecycle facts. Built either from a scanned `WALSegmentFile`
/// or from the live writer's in-memory segment state.
public struct WALSegmentLifecycleRecord: Equatable, Sendable {
    /// Manifest file form, `wal/<epoch>.<segment>.xlwal` (wal.md §7).
    public var file: String
    public var epoch: UInt64
    public var segment: UInt64
    /// The segment header's `first_mseq` (wal.md §2).
    public var firstMseq: UInt64
    /// Highest mutation mseq in the segment, 0 when it has no mutation.
    public var lastMutationMseq: UInt64
    /// Whether the segment file holds at least one record (mutation or close).
    public var hasRecords: Bool
    /// Whether the segment carries an epoch-close (`op 0xFF`) record.
    public var hasEpochClose: Bool

    public init(file: String,
                epoch: UInt64,
                segment: UInt64,
                firstMseq: UInt64,
                lastMutationMseq: UInt64,
                hasRecords: Bool,
                hasEpochClose: Bool) {
        self.file = file
        self.epoch = epoch
        self.segment = segment
        self.firstMseq = firstMseq
        self.lastMutationMseq = lastMutationMseq
        self.hasRecords = hasRecords
        self.hasEpochClose = hasEpochClose
    }

    /// Facts of one scanned segment.
    public init(segment: WALSegmentFile) {
        self.init(file: segment.manifestFile,
                  epoch: segment.epoch,
                  segment: segment.segment,
                  firstMseq: segment.header.firstMseq,
                  lastMutationMseq: segment.lastMutationMseq,
                  hasRecords: !segment.records.isEmpty,
                  hasEpochClose: segment.hasEpochClose)
    }

    /// Ranges are never inverted for a segment that holds a mutation
    /// (`first_mseq <= last_mseq`). A header-only or idle-close segment has no
    /// mutation, so `last_mseq == 0` is the wal.md §7 "0 when none" form and is
    /// not compared to `first_mseq`.
    public var hasInvertedMutationRange: Bool {
        lastMutationMseq > 0 && lastMutationMseq < firstMseq
    }
}

/// The single owner of segment/manifest/truncation decisions (wal.md §7.2, §9).
public enum WALSegmentLifecycle {
    /// Sorts lifecycle records in `<epoch, segment>` order.
    public static func sorted(_ records: [WALSegmentLifecycleRecord]) -> [WALSegmentLifecycleRecord] {
        records.sorted { lhs, rhs in
            if lhs.epoch != rhs.epoch { return lhs.epoch < rhs.epoch }
            return lhs.segment < rhs.segment
        }
    }

    /// The manifest view of the WAL: every segment that holds at least one
    /// record, sorted, with its real header/range. Header-only segments are
    /// omitted: they are not content and listing them produced the inverted
    /// `{first_mseq: 1, last_mseq: 0}` entry the defect evidence shows.
    public static func manifestSegments(
        _ records: [WALSegmentLifecycleRecord]) -> [ManifestSegment] {
        sorted(records).filter(\.hasRecords).map { record in
            ManifestSegment(file: record.file,
                            epoch: record.epoch,
                            firstMseq: record.firstMseq,
                            lastMseq: record.lastMutationMseq)
        }
    }

    /// The §9 read-back half: every mutation in the segment's own verified
    /// records is at or below `materialized_upto_mseq`. The manifest range is
    /// not the proof; a stale manifest may record a shorter range than the
    /// file, so the caller passes the records it just read back.
    public static func everyMutationAtOrBelow(
        _ records: [WALRecord], watermark: UInt64) -> Bool {
        records.allSatisfy { record in
            record.isEpochClose || record.mseq <= watermark
        }
    }

    /// The segment carrying the newest epoch-close record: never droppable
    /// (wal.md §9).
    public static func newestEpochClose(
        _ records: [WALSegmentLifecycleRecord]) -> WALSegmentLifecycleRecord? {
        records.filter(\.hasEpochClose).max { lhs, rhs in
            if lhs.epoch != rhs.epoch { return lhs.epoch < rhs.epoch }
            return lhs.segment < rhs.segment
        }
    }

    /// Whether `record` can be truncated (wal.md §9, decided reading):
    ///
    ///   * it is listed in the durable manifest's `segments[]`;
    ///   * its epoch is at or below the manifest's `last_durable_epoch`;
    ///   * it is not the current open epoch/segment;
    ///   * every mutation in its own records is at or below the strictly
    ///     contiguous materialized watermark;
    ///   * it is not the retained segment carrying the newest epoch close.
    ///
    /// The caller supplies `allMutationsAtOrBelowWatermark` after reading the
    /// candidate's records back; the manifest's `last_mseq` is never the proof
    /// of condition 4. A stale/unlisted segment is passed with
    /// `listedFiles` not containing it and is therefore retained.
    public static func isDroppable(
        _ record: WALSegmentLifecycleRecord,
        listedFiles: Set<String>,
        lastDurableEpoch: UInt64,
        materializedUptoMseq: UInt64,
        newestEpochClose: WALSegmentLifecycleRecord?,
        isCurrent: Bool,
        allMutationsAtOrBelowWatermark: Bool
    ) -> Bool {
        guard !isCurrent else { return false }
        guard listedFiles.contains(record.file) else { return false }
        guard record.epoch <= lastDurableEpoch else { return false }
        guard allMutationsAtOrBelowWatermark else { return false }
        guard record.lastMutationMseq <= materializedUptoMseq else { return false }
        if let newestEpochClose,
           newestEpochClose.epoch == record.epoch,
           newestEpochClose.segment == record.segment {
            return false
        }
        return true
    }

    /// Structural validation of a decoded manifest (wal.md §7). The manifest is
    /// a durable checkpoint, so an impossible value is `WAL_CORRUPT` and the
    /// host must fail loud rather than act on it.
    public static func validate(_ manifest: Manifest) throws {
        guard manifest.materializedUptoMseq <= manifest.lastMseq else {
            throw LogError.corrupt(
                "manifest materialized_upto_mseq \(manifest.materializedUptoMseq) is above last_mseq \(manifest.lastMseq)")
        }
        var seen = Set<String>()
        for segment in manifest.segments {
            guard segment.epoch >= 1 else {
                throw LogError.corrupt("manifest lists epoch \(segment.epoch)")
            }
            guard segment.firstMseq >= 1 else {
                throw LogError.corrupt("manifest lists first_mseq \(segment.firstMseq)")
            }
            guard seen.insert(segment.file).inserted else {
                throw LogError.corrupt("manifest lists segment \(segment.file) twice")
            }
            guard !WALSegmentLifecycleRecord(
                file: segment.file,
                epoch: segment.epoch,
                segment: 0,
                firstMseq: segment.firstMseq,
                lastMutationMseq: segment.lastMseq,
                hasRecords: true,
                hasEpochClose: false).hasInvertedMutationRange else {
                throw LogError.corrupt(
                    "manifest segment \(segment.file) has first_mseq \(segment.firstMseq) above last_mseq \(segment.lastMseq)")
            }
        }
    }

    /// Validates a manifest entry against the real segment file found on disk.
    ///
    /// The manifest may lag the newest segment: a crash between a record write
    /// and the next manifest rewrite leaves the real range longer than the
    /// recorded one, and recovery adopts the difference. It may also be longer
    /// than the real range only for the newest segment, where D19 truncates a
    /// torn tail — and only below the materialized watermark, because a lost
    /// record above it is unrepairable history.
    public static func validateListedRange(
        _ listed: ManifestSegment,
        segment: WALSegmentFile,
        materializedUptoMseq: UInt64,
        isNewest: Bool,
        tornTailTruncated: Bool) throws {
        guard segment.epoch == listed.epoch,
              segment.header.firstMseq == listed.firstMseq else {
            throw LogError.corrupt(
                "manifest and WAL disagree on the header of \(listed.file)")
        }
        if segment.lastMutationMseq >= listed.lastMseq { return }
        // The file now holds fewer records than the manifest recorded.
        guard isNewest, tornTailTruncated, listed.lastMseq <= materializedUptoMseq else {
            throw LogError.corrupt(
                "manifest and WAL disagree on the range of \(listed.file)")
        }
    }

    /// Manifest invariants the writer asserts before every atomic rewrite.
    /// `knownLastMseq` is the highest level-1 accepted mseq; a checkpoint may
    /// never name a higher position and may never invert a segment range.
    public static func assertConsistent(_ manifest: Manifest,
                                        knownLastMseq: UInt64) throws {
        if manifest.lastMseq > knownLastMseq {
            throw LogError.corrupt(
                "manifest last_mseq \(manifest.lastMseq) is above the accepted tail \(knownLastMseq)")
        }
        if manifest.materializedUptoMseq > manifest.lastMseq {
            throw LogError.corrupt(
                "manifest materialized_upto_mseq \(manifest.materializedUptoMseq) is above last_mseq \(manifest.lastMseq)")
        }
        var seen = Set<String>()
        for segment in manifest.segments {
            guard segment.firstMseq >= 1 else {
                throw LogError.corrupt("manifest lists first_mseq \(segment.firstMseq)")
            }
            guard seen.insert(segment.file).inserted else {
                throw LogError.corrupt("manifest lists segment \(segment.file) twice")
            }
            if segment.lastMseq > 0, segment.lastMseq < segment.firstMseq {
                throw LogError.corrupt(
                    "manifest segment \(segment.file) has first_mseq \(segment.firstMseq) above last_mseq \(segment.lastMseq)")
            }
        }
    }
}
