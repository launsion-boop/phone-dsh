// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the host's durable ledger of future work.
//
// host contract `spec/host/v1/README.md` §10.3 (engine-launch-v1 revision 2):
//   I1 the intent lands on the host before anything else;
//   I2 every future due point is one WakeDemand here, not a timer in the
//      engine or in process memory;
//   I5 whenever the ledger changes, the App enters the background or a host
//      parks, the projection (§10.3.3) is recomputed and submitted to the OS.
//
// Storage: one host-private JSON document under Application Support
// (`phone-dsh/wake-demands.json`), written atomically. The format is not
// shared, but the value semantics, the closed source set and the projection
// are contract. A missing document is an empty ledger; a corrupt one is moved
// aside and treated as empty (a lost demand delays work, it never loses the
// durable journal it points at).

import Foundation

/// Whether a demand fires once or keeps moving its next due time.
public enum WakeDemandKind: String, Codable, Sendable, Equatable {
    case once
    case recurring
}

/// The closed demand source set (§10.3.2). The declaration order is the
/// contract's `demandSources` order, used to break `dueNow` ties.
public enum WakeDemandSource: String, CaseIterable, Codable, Sendable, Equatable {
    case botRoutine
    case connectorScan
    case dshSchedule
    case hostRetry

    /// 0-based position in `demandSources`.
    public var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

/// The typed rejection reasons the golden's invalid vectors use (§10.3.3:
/// unknown source/kind, duplicate identity, negative due time, malformed
/// member). A decoder must reject with exactly one of these; it never coerces.
public enum WakeContractError: String, Error, Equatable {
    case missingMember = "missing-member"
    case memberType = "member-type"
    case unknownSource = "unknown-source"
    case unknownKind = "unknown-kind"
    case duplicateDemand = "duplicate-demand"
    case dueNegative = "due-negative"
}

/// The ledger could not be read or written *now*. The bytes on disk are
/// intact: retry after protected data becomes available (I1/I2). This is
/// never reported as corruption and never overwrites the file.
public enum WakeDemandLedgerError: Error, Equatable {
    case unavailable
}

/// One future due point owned by the host.
public struct WakeDemand: Codable, Equatable, Sendable, Identifiable {
    public var source: WakeDemandSource
    /// Source-local identity; `(source, key)` is the upsert key.
    /// `[A-Za-z0-9._:-]{1,128}`.
    public var key: String
    public var dueAtMs: Int64
    public var kind: WakeDemandKind
    /// A user-visible demand also gets the source's own local notification
    /// (routine, DSH reminder); a silent one relies on the background channels.
    public var userVisible: Bool

    public var id: String { "\(source.rawValue):\(key)" }

    public init(source: WakeDemandSource, key: String, dueAtMs: Int64,
                kind: WakeDemandKind, userVisible: Bool) {
        self.source = source
        self.key = key
        self.dueAtMs = dueAtMs
        self.kind = kind
        self.userVisible = userVisible
    }

    /// `[A-Za-z0-9._:-]{1,128}` (§10.3.2).
    public static func isValidKey(_ key: String) -> Bool {
        guard (1...128).contains(key.utf8.count) else { return false }
        return key.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45...57, 58, 46, 65...90, 95, 97...122: return true // - . : 0-9 A-Z _ a-z
            default: return false
            }
        }
    }

    public func isDue(nowMs: Int64) -> Bool { dueAtMs <= nowMs }

    // MARK: - Strict coding

    enum CodingKeys: String, CodingKey {
        case source
        case key
        case dueAtMs
        case kind
        case userVisible
    }

    public init(from decoder: Decoder) throws {
        do {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let sourceName = try c.decode(String.self, forKey: .source)
            guard let source = WakeDemandSource(rawValue: sourceName) else {
                throw WakeContractError.unknownSource
            }
            let kindName = try c.decode(String.self, forKey: .kind)
            guard let kind = WakeDemandKind(rawValue: kindName) else {
                throw WakeContractError.unknownKind
            }
            let key = try c.decode(String.self, forKey: .key)
            guard Self.isValidKey(key) else { throw WakeContractError.memberType }
            let dueAtMs = try c.decode(Int64.self, forKey: .dueAtMs)
            guard dueAtMs >= 0 else { throw WakeContractError.dueNegative }
            self.init(source: source, key: key, dueAtMs: dueAtMs, kind: kind,
                      userVisible: try c.decode(Bool.self, forKey: .userVisible))
        } catch let error as WakeContractError {
            throw error
        } catch DecodingError.keyNotFound {
            throw WakeContractError.missingMember
        } catch DecodingError.valueNotFound {
            throw WakeContractError.missingMember
        } catch DecodingError.typeMismatch {
            throw WakeContractError.memberType
        } catch {
            throw WakeContractError.memberType
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source.rawValue, forKey: .source)
        try c.encode(key, forKey: .key)
        try c.encode(dueAtMs, forKey: .dueAtMs)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(userVisible, forKey: .userVisible)
    }
}

/// The persisted document (host-private format).
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

    public func all() throws -> [WakeDemand] {
        try ensureLoaded()
        return demands.keys.sorted().compactMap { demands[$0] }
    }

    public func demand(source: WakeDemandSource, key: String) throws -> WakeDemand? {
        try ensureLoaded()
        return demands["\(source.rawValue):\(key)"]
    }

    /// The demand with the earliest due time (ties by id).
    public func nextDemand() throws -> WakeDemand? {
        try ensureLoaded()
        return demands.values.min { lhs, rhs in
            lhs.dueAtMs != rhs.dueAtMs ? lhs.dueAtMs < rhs.dueAtMs : lhs.id < rhs.id
        }
    }

    public func earliestDueAt() throws -> Int64? {
        try nextDemand()?.dueAtMs
    }

    /// Demands whose due time has passed, in contract `dueNow` order:
    /// `dueAtMs`, then source order, then key.
    public func dueDemands(nowMs: Int64) throws -> [WakeDemand] {
        try ensureLoaded()
        return demands.values
            .filter { $0.dueAtMs <= nowMs }
            .sorted(by: WakeProjection.dueOrder)
    }

    public func dueDemands(source: WakeDemandSource, nowMs: Int64) throws -> [WakeDemand] {
        try dueDemands(nowMs: nowMs).filter { $0.source == source }
    }

    // MARK: - Writes

    /// Upsert by `(source, key)`: the newest due time, kind and visibility win.
    /// Invalid values are rejected, never coerced (§10.3.3).
    public func upsert(_ demand: WakeDemand) throws {
        guard WakeDemand.isValidKey(demand.key), demand.dueAtMs >= 0 else {
            throw WakeContractError.memberType
        }
        try ensureLoaded()
        let previous = demands[demand.id]
        demands[demand.id] = demand
        do { try persist() } catch {
            if let previous { demands[demand.id] = previous } else { demands.removeValue(forKey: demand.id) }
            throw error
        }
    }

    public func remove(source: WakeDemandSource, key: String) throws {
        try ensureLoaded()
        let previous = demands.removeValue(forKey: "\(source.rawValue):\(key)")
        guard let previous else { return }
        do { try persist() } catch {
            demands[previous.id] = previous
            throw error
        }
    }

    public func removeAll(source: WakeDemandSource) throws {
        try ensureLoaded()
        let snapshot = demands
        demands = demands.filter { $0.value.source != source }
        guard demands.count != snapshot.count else { return }
        do { try persist() } catch {
            demands = snapshot
            throw error
        }
    }

    /// Drops every due `once` demand after its consumer ran. A recurring
    /// demand is left to its producer (it owns the next due time).
    public func removeConsumedOnceDemands(source: WakeDemandSource, nowMs: Int64) throws {
        try ensureLoaded()
        let doomed = demands.values.filter {
            $0.source == source && $0.kind == .once && $0.dueAtMs <= nowMs
        }
        guard !doomed.isEmpty else { return }
        let snapshot = demands
        for demand in doomed { demands.removeValue(forKey: demand.id) }
        do { try persist() } catch {
            demands = snapshot
            throw error
        }
    }

    // MARK: - Persistence

    /// Loads once. A read failure (data protection before first unlock,
    /// permissions, I/O) is *not* corruption: the bytes stay where they are,
    /// `loaded` stays false and the caller gets `unavailable` to retry later.
    /// Only bytes that were actually read and are not valid JSON are treated
    /// as corruption.
    private func ensureLoaded() throws {
        guard !loaded else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loaded = true
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw WakeDemandLedgerError.unavailable
        }
        do {
            let document = try JSONDecoder().decode(WakeDemandDocument.self, from: data)
            demands = Dictionary(uniqueKeysWithValues: document.demands.map { ($0.id, $0) })
            loaded = true
        } catch {
            // Preserve the bytes for diagnosis, then start empty: the durable
            // work behind a demand (outbox, journal, routine store) is intact.
            let backup = fileURL.appendingPathExtension("corrupt-\(Self.nowMs())")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            demands = [:]
            loaded = true
        }
    }

    private func persist() throws {
        let document = WakeDemandDocument(demands: demands.keys.sorted().compactMap { demands[$0] })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".wake-demands-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        // `.completeUntilFirstUserAuthentication`, not `.complete`: a background
        // push/BGTask wake arrives while the phone is locked, and the ledger is
        // exactly what authorizes that wake. `.complete` would make the file
        // unreadable until the user unlocks.
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }
}
