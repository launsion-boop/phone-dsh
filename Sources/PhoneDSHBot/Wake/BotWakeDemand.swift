// SPDX-License-Identifier: MIT

import Foundation

/// One future due point the Bot side owns, in the host's neutral vocabulary.
///
/// PLAN §2.9 I2: the timing of future Bot work cannot live only in the engine
/// or this process's memory. The App adapter maps this value onto the durable
/// `WakeDemand` ledger (`source`, `key`, `dueAtMs`, `kind`, `userVisible`) and
/// the launch orchestrator projects the earliest due time onto the OS wake
/// channels. SwiftPM stays free of the ProbeKit/UIKit ledger types.
public struct BotWakeDemand: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case once
        case recurring
    }

    public var source: String
    public var key: String
    public var dueAtMs: Int64
    public var kind: Kind
    public var userVisible: Bool

    public init(source: String, key: String, dueAtMs: Int64,
                kind: Kind = .recurring, userVisible: Bool = false) {
        self.source = source
        self.key = key
        self.dueAtMs = dueAtMs
        self.kind = kind
        self.userVisible = userVisible
    }

    /// One demand per Bot: the earliest `nextRunAt` across its routines.
    public static let botRoutineSource = "botRoutine"
    /// The connector scan's own cadence (minimum interval is a contract
    /// constant; the App decides whether it is available yet).
    public static let connectorScanSource = "connectorScan"
}

/// The durable sink the App installs over `WakeDemandLedger` +
/// `EngineLaunchOrchestrator`. Operations are idempotent by `(source, key)`.
public protocol BotWakeDemanding: Sendable {
    func upsert(_ demand: BotWakeDemand) async
    func remove(source: String, key: String) async
    func removeAll(source: String) async
}


/// Per-Bot last-written due time. The routine scheduler re-projects after
/// every tick, but the durable ledger must only be rewritten when the earliest
/// due time actually moved (or the demand appeared/disappeared). The cache is
/// process-local and safe to lose: the ledger is the authority.
public final class BotWakeDemandCache: @unchecked Sendable {
    private let lock = NSLock()
    private var dueAtMs: Int64?
    private var present = false

    public init() {}

    /// True when this due time was not the last one written for the source.
    public func shouldUpsert(dueAtMs: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if present && self.dueAtMs == dueAtMs { return false }
        present = true
        self.dueAtMs = dueAtMs
        return true
    }

    /// True when a previously written demand must now be removed.
    public func shouldRemove() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard present else { return false }
        present = false
        dueAtMs = nil
        return true
    }
}
