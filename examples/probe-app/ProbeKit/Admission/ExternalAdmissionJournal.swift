// SPDX-License-Identifier: MIT
// External admission journal (P06; spec/host/v1/external-admission.md,
// revision external-admission-v1).
//
// A request that arrives from outside the composer is written here first and
// only then handed to the owner that executes it. One file per record,
// `admissions/<admissionId>.json`, written with the same atomic order as the
// send outbox (temp → fsync → rename → directory fsync, mode 0600). The
// journal records that the request was admitted and which `downstreamId`
// carries it; it never executes anything and never boots an engine.
//
// Opening needs no Worker, engine or Bot runtime: it is a directory read. A
// file that does not decode as a v1 record is left untouched, counted toward
// the directory bound, never dispatched and never deleted.

import Foundation
import Darwin

public actor ExternalAdmissionJournal {
    public typealias Writer = @Sendable (Data, URL) throws -> Void

    public nonisolated let directory: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let writer: Writer

    private var opened = false
    private var protectionApplied = false
    private var records: [String: ExternalAdmissionRecord] = [:]
    /// Directory entries this version does not interpret (corrupt, newer
    /// version, foreign files). They count toward the 2048 bound.
    private var opaqueNames: Set<String> = []

    /// `write` is the single durable-write step every admission and transition
    /// goes through; tests replace it to stop a write at the crash boundary.
    public init(directory: URL,
                write: @escaping Writer = { try SendOutbox.atomicWrite($0, to: $1) }) {
        self.directory = directory
        self.writer = write
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public static func nowMs(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    // MARK: - Admission

    /// One decision followed by one atomic write (external-admission.md §2).
    /// Checks run in the table's order: invalid, duplicate / conflict,
    /// capacity, then the write itself decides `storage` or `admitted`.
    public func admit(_ request: ExternalAdmissionRequest,
                      nowMs: Int64 = ExternalAdmissionJournal.nowMs()) -> ExternalAdmissionOutcome {
        guard let candidate = ExternalAdmissionPolicy.candidate(for: request, nowMs: nowMs) else {
            return ExternalAdmissionOutcome(result: .invalid)
        }
        // Without a readable directory neither a duplicate nor a conflict can
        // be ruled out, so nothing is written and there is no receipt.
        guard open(nowMs: nowMs) else { return ExternalAdmissionOutcome(result: .storage) }
        if let existing = records[candidate.admissionId] {
            let same = existing.target == candidate.target
                && existing.contentSha256 == candidate.contentSha256
            return same
                ? ExternalAdmissionOutcome(result: .duplicate, receipt: Self.receipt(existing))
                : ExternalAdmissionOutcome(result: .conflict)
        }
        // v1.1 §2: a file with this name that this version cannot decode is
        // never overwritten. It is decided here, where `duplicate` would be:
        // after `invalid` and before `capacity`.
        guard !opaqueNames.contains(Self.fileName(candidate.admissionId)) else {
            return ExternalAdmissionOutcome(result: .storage)
        }
        guard pendingCount < ExternalAdmissionLimits.maxPending,
              entryCount < ExternalAdmissionLimits.maxEntries else {
            return ExternalAdmissionOutcome(result: .capacity)
        }
        do { try write(candidate) } catch {
            return ExternalAdmissionOutcome(result: .storage)
        }
        return ExternalAdmissionOutcome(result: .admitted, receipt: Self.receipt(candidate))
    }

    // MARK: - Reading

    public func record(admissionId: String,
                       nowMs: Int64 = ExternalAdmissionJournal.nowMs()) -> ExternalAdmissionRecord? {
        guard open(nowMs: nowMs) else { return nil }
        return records[admissionId]
    }

    /// Every decodable record, ordered by (`admittedAtMs`, `admissionId`).
    public func allRecords(nowMs: Int64 = ExternalAdmissionJournal.nowMs()) -> [ExternalAdmissionRecord] {
        guard open(nowMs: nowMs) else { return [] }
        return records.values.sorted {
            if $0.admittedAtMs != $1.admittedAtMs { return $0.admittedAtMs < $1.admittedAtMs }
            return $0.admissionId < $1.admissionId
        }
    }

    /// Records handed over and waiting for the downstream owner's terminal report.
    public func linkedRecords(nowMs: Int64 = ExternalAdmissionJournal.nowMs()) -> [ExternalAdmissionRecord] {
        allRecords(nowMs: nowMs).filter { $0.stage == .linked }
    }

    public struct Counts: Equatable, Sendable {
        public let pending: Int
        public let entries: Int
        public let undecodable: Int
    }

    /// `pending`: `admitted` + `dispatching`. `entries`: everything in the
    /// directory. `undecodable`: entries this version left untouched.
    public func counts(nowMs: Int64 = ExternalAdmissionJournal.nowMs()) -> Counts {
        guard open(nowMs: nowMs) else { return Counts(pending: 0, entries: 0, undecodable: 0) }
        return Counts(pending: pendingCount, entries: entryCount, undecodable: opaqueNames.count)
    }

    // MARK: - Dispatch pass

    /// Sweeps, then returns the records of this pass in dispatch order
    /// (external-admission.md §4). Recovered `dispatching` records are included:
    /// the caller repeats the downstream write with the same `downstreamId`.
    /// `isWaiting` is the dispatcher's precheck: a record it names is only
    /// waiting for execution conditions, is skipped and does not use one of the 16.
    public func beginPass(
        nowMs: Int64 = ExternalAdmissionJournal.nowMs(),
        isWaiting: @Sendable (ExternalAdmissionRecord) -> Bool = { _ in false }
    ) -> [ExternalAdmissionRecord] {
        ExternalAdmissionPolicy.dispatchOrder(sweptPendingRecords(nowMs: nowMs), nowMs: nowMs,
                                              isWaiting: isWaiting)
    }

    /// Sweeps, then returns every pending record. A dispatcher whose precheck
    /// cannot cross into this actor selects its pass from these with
    /// ``ExternalAdmissionPolicy/dispatchOrder(_:nowMs:isWaiting:)``, the same
    /// function ``beginPass(nowMs:isWaiting:)`` uses.
    public func sweptPendingRecords(nowMs: Int64 = ExternalAdmissionJournal.nowMs()) -> [ExternalAdmissionRecord] {
        guard open(nowMs: nowMs) else { return [] }
        sweep(nowMs: nowMs)
        return records.values.filter { $0.stage.isPending }
    }

    /// Immediately before the downstream write: re-checks expiry and makes
    /// `dispatching` durable first. Returns nil when the record must not be
    /// dispatched (expired just now, already handed over, or gone). A record
    /// that is already `dispatching` is returned unchanged for the redo.
    public func beginDispatch(_ admissionId: String,
                              nowMs: Int64 = ExternalAdmissionJournal.nowMs()) throws -> ExternalAdmissionRecord? {
        guard open(nowMs: nowMs), let record = records[admissionId] else { return nil }
        switch record.stage {
        case .dispatching:
            return record
        case .admitted:
            if nowMs >= record.expiresAtMs {
                _ = try transition(admissionId, to: .expired, nowMs: nowMs)
                return nil
            }
            return try transition(admissionId, to: .dispatching, nowMs: nowMs)
        default:
            return nil
        }
    }

    /// The downstream owner durably holds `downstreamId`.
    @discardableResult
    public func markLinked(_ admissionId: String,
                           nowMs: Int64 = ExternalAdmissionJournal.nowMs()) throws -> ExternalAdmissionRecord {
        try transition(admissionId, to: .linked, nowMs: nowMs)
    }

    /// The same live sender saw the downstream write fail definitely. The
    /// record returns to `admitted` with backoff, or becomes `failed`
    /// (`retry_exhausted`) when the attempt bound would be exceeded.
    @discardableResult
    public func recordDispatchFailure(_ admissionId: String, error: String,
                                      nowMs: Int64 = ExternalAdmissionJournal.nowMs()) throws -> ExternalAdmissionRecord {
        try transition(admissionId, to: .admitted, reason: error, nowMs: nowMs)
    }

    /// The downstream owner refused definitely, or reported a failed turn.
    @discardableResult
    public func fail(_ admissionId: String, reason: String,
                     nowMs: Int64 = ExternalAdmissionJournal.nowMs()) throws -> ExternalAdmissionRecord {
        try transition(admissionId, to: .failed, reason: reason, nowMs: nowMs)
    }

    @discardableResult
    public func complete(_ admissionId: String,
                         nowMs: Int64 = ExternalAdmissionJournal.nowMs()) throws -> ExternalAdmissionRecord {
        try transition(admissionId, to: .completed, nowMs: nowMs)
    }

    @discardableResult
    public func cancel(_ admissionId: String, reason: String,
                       nowMs: Int64 = ExternalAdmissionJournal.nowMs()) throws -> ExternalAdmissionRecord {
        try transition(admissionId, to: .cancelled, reason: reason, nowMs: nowMs)
    }

    /// The target was deleted: `admitted` records for it are cancelled, and a
    /// `dispatching` one fails with `target_missing` (no cancel edge leaves
    /// `dispatching`). Handed-over records are left to the downstream owner.
    @discardableResult
    public func withdraw(target: ExternalAdmissionTarget,
                         nowMs: Int64 = ExternalAdmissionJournal.nowMs()) -> [ExternalAdmissionRecord] {
        guard open(nowMs: nowMs) else { return [] }
        var changed: [ExternalAdmissionRecord] = []
        for record in records.values where record.target == target {
            switch record.stage {
            case .admitted:
                if let next = try? transition(record.admissionId, to: .cancelled,
                                              reason: "target_deleted", nowMs: nowMs) {
                    changed.append(next)
                }
            case .dispatching:
                if let next = try? transition(record.admissionId, to: .failed,
                                              reason: "target_missing", nowMs: nowMs) {
                    changed.append(next)
                }
            default:
                break
            }
        }
        return changed
    }

    /// The account of an `account:` principal signed out (external-admission.md
    /// §3): every `admitted` record of an account other than `signedInPrincipal`
    /// becomes `cancelled`. A `dispatching` record has no cancel edge and is
    /// left for the redo; handed-over records belong to the downstream owner.
    @discardableResult
    public func cancelAccountAdmissions(
        exceptPrincipal signedInPrincipal: String?,
        nowMs: Int64 = ExternalAdmissionJournal.nowMs()) -> [ExternalAdmissionRecord] {
        guard open(nowMs: nowMs) else { return [] }
        var changed: [ExternalAdmissionRecord] = []
        for record in records.values
        where record.stage == .admitted && record.principal != "local"
            && record.principal != signedInPrincipal {
            if let next = try? transition(record.admissionId, to: .cancelled,
                                          reason: ExternalAdmissionPolicy.accountSignedOutReason,
                                          nowMs: nowMs) {
                changed.append(next)
            }
        }
        return changed
    }

    // MARK: - Transition

    /// The only way a stored record changes stage. An edge outside
    /// external-admission.md §3 throws and writes nothing. `text` is removed in
    /// the same write that leaves the pending stages.
    @discardableResult
    public func transition(_ admissionId: String, to next: ExternalAdmissionStage,
                           reason: String? = nil,
                           nowMs: Int64 = ExternalAdmissionJournal.nowMs()) throws -> ExternalAdmissionRecord {
        guard open(nowMs: nowMs) else {
            throw ExternalAdmissionError.storage("admission directory is not readable")
        }
        guard var record = records[admissionId] else { throw ExternalAdmissionError.unknownRecord }
        guard ExternalAdmissionPolicy.allows(from: record.stage, to: next) else {
            throw ExternalAdmissionError.illegalTransition(from: record.stage, to: next)
        }
        switch next {
        case .dispatching:
            record.stage = .dispatching
            record.nextAttemptAtMs = nil
        case .admitted:
            switch ExternalAdmissionPolicy.retry(attempts: record.attempts, nowMs: nowMs) {
            case let .retry(attempts, nextAttemptAtMs):
                record.stage = .admitted
                record.attempts = attempts
                record.nextAttemptAtMs = nextAttemptAtMs
                record.lastError = reason ?? "downstream_unavailable"
            case .exhausted:
                Self.settle(&record, as: .failed,
                            reason: ExternalAdmissionPolicy.retryExhaustedReason, nowMs: nowMs)
            }
        case .linked:
            record.stage = .linked
            record.text = nil
            record.lastError = nil
            record.nextAttemptAtMs = nil
            record.linkedAtMs = nowMs
        case .completed, .failed, .expired, .cancelled, .unknown:
            Self.settle(&record, as: next,
                        reason: reason ?? (next == .expired
                            ? ExternalAdmissionPolicy.expiredReason : nil),
                        nowMs: nowMs)
        }
        if let problem = record.validationProblem() {
            throw ExternalAdmissionError.invalidRecord(problem)
        }
        try write(record)
        return record
    }

    private static func settle(_ record: inout ExternalAdmissionRecord,
                               as stage: ExternalAdmissionStage, reason: String?,
                               nowMs: Int64) {
        record.stage = stage
        record.text = nil
        record.lastError = nil
        record.nextAttemptAtMs = nil
        record.settledAtMs = nowMs
        record.reason = reason
    }

    // MARK: - Sweep

    /// Runs at open and before each pass (external-admission.md §4). Pending
    /// and `linked` records are never deleted here.
    private func sweep(nowMs: Int64) {
        for record in Array(records.values) {
            switch ExternalAdmissionPolicy.sweepAction(for: record, nowMs: nowMs) {
            case .keep:
                break
            case .expire:
                _ = try? transition(record.admissionId, to: .expired, nowMs: nowMs)
            case .unknown:
                _ = try? transition(record.admissionId, to: .unknown,
                                    reason: "no_terminal_report", nowMs: nowMs)
            case .delete:
                let url = fileURL(record.admissionId)
                guard unlink(url.path) == 0 || errno == ENOENT else { continue }
                records.removeValue(forKey: record.admissionId)
                Self.fsyncDirectory(directory)
            }
        }
    }

    // MARK: - Storage

    private var pendingCount: Int { records.values.reduce(0) { $0 + ($1.stage.isPending ? 1 : 0) } }
    private var entryCount: Int { records.count + opaqueNames.count }

    private static func fileName(_ admissionId: String) -> String { "\(admissionId).json" }

    private func fileURL(_ admissionId: String) -> URL {
        directory.appendingPathComponent(Self.fileName(admissionId))
    }

    private static func receipt(_ record: ExternalAdmissionRecord) -> ExternalAdmissionReceipt {
        ExternalAdmissionReceipt(admissionId: record.admissionId,
                                 downstreamId: record.downstreamId, stage: record.stage,
                                 target: record.target)
    }

    /// Reads the directory once per journal. A missing directory is an empty
    /// journal. A file that cannot be *read* (for example before the first
    /// unlock after a restart) leaves the journal closed so the next call
    /// tries again; it is not mistaken for an undecodable record.
    private func open(nowMs: Int64) -> Bool {
        if opened { return true }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            records = [:]
            opaqueNames = []
            opened = true
            return true
        }
        guard isDirectory.boolValue,
              let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        var loaded: [String: ExternalAdmissionRecord] = [:]
        var opaque: Set<String> = []
        for name in names {
            guard name.hasSuffix(".json"),
                  AdmissionText.isLowerHex64(String(name.dropLast(5))) else {
                opaque.insert(name)
                continue
            }
            let data: Data
            do { data = try Data(contentsOf: directory.appendingPathComponent(name)) } catch {
                return false
            }
            if let record = try? decoder.decode(ExternalAdmissionRecord.self, from: data),
               Self.fileName(record.admissionId) == name {
                loaded[record.admissionId] = record
            } else {
                opaque.insert(name)
            }
        }
        records = loaded
        opaqueNames = opaque
        opened = true
        sweep(nowMs: nowMs)
        return true
    }

    private func write(_ record: ExternalAdmissionRecord) throws {
        do {
            try prepareDirectory()
            let data = try encoder.encode(record)
            let url = fileURL(record.admissionId)
            try writer(data, url)
            // The directory's class is inherited by the temporary file the
            // write renames; this states it on the record file as well.
            try? fileManager.setAttributes(Self.protection, ofItemAtPath: url.path)
        } catch let error as ExternalAdmissionError {
            throw error
        } catch {
            throw ExternalAdmissionError.storage(String(describing: error))
        }
        records[record.admissionId] = record
    }

    private static var protection: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    /// `admissions/` carries `completeUntilFirstUserAuthentication` explicitly,
    /// so a record admitted on a locked phone stays readable and writable. The
    /// parent tree is created without touching its own protection class.
    private func prepareDirectory() throws {
        guard !protectionApplied else { return }
        try fileManager.createDirectory(at: directory.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: Self.protection)
        }
        try? fileManager.setAttributes(Self.protection, ofItemAtPath: directory.path)
        protectionApplied = true
    }

    private static func fsyncDirectory(_ url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }
}
