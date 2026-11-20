// SPDX-License-Identifier: MIT

import Foundation

/// PLAN §2.9 I2: project a Bot's routines onto the host's durable demand
/// ledger. One demand per Bot carries the earliest due occurrence; it is
/// `recurring` and user-visible because the routine notification is the
/// user-facing channel. A Bot with no runnable routine removes its demand.
///
/// Exclusions match the scheduler's own admission rule: an enabled routine
/// with a future `nextRunAt`, not parked on an approval and not waiting for
/// reconciliation. Quiet-hour deferral is already folded into `nextRunAt`.
public enum RoutineDemandProjection {
    public static func earliestDueAt(_ routines: [Routine]) -> Int64? {
        routines.compactMap { routine -> Int64? in
            guard routine.enabled, let nextRunAt = routine.nextRunAt else { return nil }
            switch routine.runState?.status {
            case .needsReconciliation, .waitingApproval:
                return nil
            default:
                return nextRunAt
            }
        }.min()
    }

    public static func demand(botID: String, routines: [Routine]) -> BotWakeDemand? {
        guard let dueAt = earliestDueAt(routines), !botID.isEmpty else { return nil }
        return BotWakeDemand(source: BotWakeDemand.botRoutineSource, key: botID,
                             dueAtMs: dueAt, kind: .recurring, userVisible: true)
    }
}
