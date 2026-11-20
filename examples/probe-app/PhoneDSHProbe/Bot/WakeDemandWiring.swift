// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot
import ProbeKit

/// App adapter from the Bot's neutral `BotWakeDemanding` surface to the host's
/// durable `WakeDemand` ledger (PLAN §2.9 I2).
///
/// The SwiftPM Bot modules never import ProbeKit or touch the ledger file. The
/// orchestrator owns the ledger, the resident timer and the BGTask/refresh
/// projection; this adapter only translates one value and forwards one write.
/// Every operation is idempotent by `(source, key)` in the ledger itself.
@MainActor
enum WakeDemandWiring {
    static func install(on composition: BotRuntimeComposition) async {
        await composition.installWakeDemandSink(WakeDemandLedgerAdapter())
        // The connector scan's recurring cadence is a frozen contract constant
        // (r3). Until that constant is in the contract tree, the scan stays
        // wake-driven and no local interval is invented; the ReadySweep source
        // still runs the scan on every wake.
        composition.connectorScanDemandIntervalMs = nil
    }
}

/// Stateless: the ledger and the orchestrator own all state. The protocol is
/// nonisolated (`Sendable`), so each write hops to the main actor where the
/// orchestrator lives.
private final class WakeDemandLedgerAdapter: BotWakeDemanding, @unchecked Sendable {
    func upsert(_ demand: BotWakeDemand) async {
        guard let source = WakeDemandSource(rawValue: demand.source) else { return }
        let value = WakeDemand(
            source: source,
            key: demand.key,
            dueAtMs: demand.dueAtMs,
            kind: demand.kind == .once ? .once : .recurring,
            userVisible: demand.userVisible)
        await EngineLaunchOrchestrator.shared.upsertWakeDemand(value)
    }

    func remove(source: String, key: String) async {
        guard let source = WakeDemandSource(rawValue: source) else { return }
        await EngineLaunchOrchestrator.shared.removeWakeDemand(source: source, key: key)
    }

    func removeAll(source: String) async {
        guard let source = WakeDemandSource(rawValue: source) else { return }
        await EngineLaunchOrchestrator.shared.removeWakeDemands(source: source)
    }
}
