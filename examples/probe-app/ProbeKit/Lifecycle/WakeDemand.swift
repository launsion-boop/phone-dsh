// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the host's durable ledger of future work.
//
// PLAN §2.9 invariants I1/I2/I5 (host contract §10.3):
//   I1 the intent lands on the host before anything else;
//   I2 every future due time is one WakeDemand here, not a timer in the
//      engine or in this process's memory;
//   I5 before the process suspends, the earliest `dueAt` is projected onto
//      every OS wake channel; losing a wake only delays work, because any
//      later wake sweeps every due demand.
//
// Storage: one private JSON document under Application Support
// (`phone-dsh/wake-demands.json`), written atomically. A missing document is
// an empty ledger; a corrupt one is moved aside and treated as empty (a lost
// demand delays work, it never loses the durable journal it points at).

import Foundation

/// Whether a demand fires once or keeps a next due time.
public enum WakeDemandKind: String, Codable, Sendable, Equatable {
    case once
    case recurring
}

/// The closed set of producers that may write a demand (PLAN §2.9 audit; the
/// contract freezes the final identifiers). `botRoutine` is the Bot side's
/// routine mirror; `missedRoutines` is its ReadySweep consumer.
public enum WakeDemandSource: String, CaseIterable, Codable, Sendable, Equatable {
    case userOutbox
    case externalAdmission
    case cloudTaskPull
    case botHeldInbox
    case missedRoutines
    case connectorScan
    case approvalReminderSync
    case dshSchedule
    case hostRetries
    case botRoutine
}

/// One future due point owned by the host.
public struct WakeDemand: Codable, Equatable, Sendable, Identifiable {
    public var source: WakeDemandSource
    /// Source-local identity; `(source, key)` is the upsert key.
    public var key: String
    public var dueAtMs: Int64
    public var kind: WakeDemandKind
    /// A user-visible demand also gets a local notification (routine, DSH
    /// reminder); a silent one relies on the background-task projection.
    public var userVisible: Bool
    public var updatedAtMs: Int64

    public var id: String { "\(source.rawValue):\(key)" }

    public init(source: WakeDemandSource, key: String, dueAtMs: Int64,
                kind: WakeDemandKind, userVisible: Bool,
                updatedAtMs: Int64 = WakeDemandLedger.nowMs()) {
        self.source = source
        self.key = key
        self.dueAtMs = dueAtMs
        self.kind = kind
        self.userVisible = userVisible
        self.updatedAtMs = updatedAtMs
    }

    public func isDue(nowMs: Int64) -> Bool { dueAtMs <= nowMs }
}

/// The persisted document.
public struct WakeDemandDocument: Codable, Equatable, Sendable {
    public var version: Int
    public var demands: [WakeDemand]

    public init(version: Int = 1, demands: [WakeDemand] = []) {
        self.version = version
        self.demands = demands
    }
}

/// Durable, idempotent-by-`(source, key)` store of ``WakeDemand`` values.
public actor WakeDemandLedger {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("wake-demands.json") }

    private var loaded = false
    private var demands: [String: WakeDemand] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    /// The App's private ledger location, beside the send outbox.
    public static func applicationSupport() -> WakeDemandLedger {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
        return WakeDemandLedger(
            directory: base.appendingPathComponent("phone-dsh", isDirectory: true))
    }

    public static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: - Reads

    public func all() -> [WakeDemand] {
        ensureLoaded()
        return demands.keys.sorted().compactMap { demands[$0] }
    }

    public func demand(source: WakeDemandSource, key: String) -> WakeDemand? {
        ensureLoaded()
        return demands["\(source.rawValue):\(key)"]
    }

    /// The earliest future-or-due demand, or `nil` when the ledger is empty.
    public func nextDemand() -> WakeDemand? {
        ensureLoaded()
        return demands.values.min { lhs, rhs in
            lhs.dueAtMs != rhs.dueAtMs ? lhs.dueAtMs < rhs.dueAtMs : lhs.id < rhs.id
        }
    }

    public func earliestDueAt() -> Int64? {
        nextDemand()?.dueAtMs
    }

    /// Demands whose due time has passed, in (`dueAtMs`, id) order.
    public func dueDemands(nowMs: Int64) -> [WakeDemand] {
        ensureLoaded()
        return demands.values
            .filter { $0.dueAtMs <= nowMs }
            .sorted { lhs, rhs in
                lhs.dueAtMs != rhs.dueAtMs ? lhs.dueAtMs < rhs.dueAtMs : lhs.id < rhs.id
            }
    }

    public func dueDemands(source: WakeDemandSource, nowMs: Int64) -> [WakeDemand] {
        dueDemands(nowMs: nowMs).filter { $0.source == source }
    }

    // MARK: - Writes

    /// Upsert by `(source, key)`: the newest due time, kind and visibility win.
    public func upsert(_ demand: WakeDemand) throws {
        ensureLoaded()
        demands[demand.id] = demand
        try persist()
    }

    public func remove(source: WakeDemandSource, key: String) throws {
        ensureLoaded()
        if demands.removeValue(forKey: "\(source.rawValue):\(key)") != nil {
            try persist()
        }
    }

    public func removeAll(source: WakeDemandSource) throws {
        ensureLoaded()
        let before = demands.count
        demands = demands.filter { $0.value.source != source }
        if demands.count != before { try persist() }
    }

    /// Drops every due `once` demand after its consumer ran. A recurring
    /// demand is left to its producer (it owns the next due time).
    public func removeConsumedOnceDemands(source: WakeDemandSource, nowMs: Int64) throws {
        ensureLoaded()
        let doomed = demands.values.filter {
            $0.source == source && $0.kind == .once && $0.dueAtMs <= nowMs
        }
        guard !doomed.isEmpty else { return }
        for demand in doomed { demands.removeValue(forKey: demand.id) }
        try persist()
    }

    // MARK: - Persistence

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(WakeDemandDocument.self, from: data)
            demands = Dictionary(uniqueKeysWithValues: document.demands.map { ($0.id, $0) })
        } catch {
            // Preserve the bytes for diagnosis, then start empty: the durable
            // work behind a demand (outbox, journal, routine store) is intact.
            let backup = fileURL.appendingPathExtension("corrupt-\(Self.nowMs())")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            demands = [:]
        }
    }

    private func persist() throws {
        let document = WakeDemandDocument(demands: demands.keys.sorted().compactMap { demands[$0] })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".wake-demands-\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
    }
}
