// SPDX-License-Identifier: MIT

import Foundation

public actor BotStreamingRowLimiter {
    public static let maximumUpdatesPerSecond = 10

    private var visible: [String: BotRow] = [:]
    private var pending: [String: BotRow] = [:]
    private var pendingOrder: [String: Int] = [:]
    private var insertionCounter = 0
    private var emissions: [TimeInterval] = []
    private var lastNow: TimeInterval = 0

    public init() {}

    @discardableResult
    public func submit(_ row: BotRow, now: TimeInterval) -> BotRow? {
        let clock = monotonic(now)
        prune(clock)
        let overlay = row.replacing(updatedSeq: row.updatedSeq, streaming: true)
        if pending[overlay.id] == nil {
            pendingOrder[overlay.id] = insertionCounter
            insertionCounter += 1
        }
        pending[overlay.id] = overlay
        guard emissions.count < Self.maximumUpdatesPerSecond else { return nil }
        return emit(id: overlay.id, now: clock)
    }

    public func flush(now: TimeInterval) -> [BotRow] {
        let clock = monotonic(now)
        prune(clock)
        var output: [BotRow] = []
        while emissions.count < Self.maximumUpdatesPerSecond, let id = nextPendingID() {
            if let row = emit(id: id, now: clock) { output.append(row) }
        }
        return output
    }

    public func rows() -> [BotRow] {
        visible.values.sorted { lhs, rhs in
            if lhs.seq != rhs.seq { return lhs.seq < rhs.seq }
            return lhs.id < rhs.id
        }
    }

    public func pendingCount() -> Int { pending.count }

    public func nextFlushAt() -> TimeInterval? {
        guard !pending.isEmpty else { return nil }
        return emissions.sorted().first.map { $0 + 1 }
    }

    public func remove(id: String) {
        pending.removeValue(forKey: id)
        pendingOrder.removeValue(forKey: id)
        visible.removeValue(forKey: id)
    }

    public func clear() {
        pending.removeAll()
        pendingOrder.removeAll()
        visible.removeAll()
        emissions.removeAll()
    }

    private func monotonic(_ now: TimeInterval) -> TimeInterval {
        lastNow = max(lastNow, now)
        return lastNow
    }

    private func prune(_ now: TimeInterval) {
        emissions.removeAll { $0 <= now - 1 }
    }

    private func nextPendingID() -> String? {
        pending.keys.min { lhs, rhs in
            (pendingOrder[lhs] ?? Int.max) < (pendingOrder[rhs] ?? Int.max)
        }
    }

    private func emit(id: String, now: TimeInterval) -> BotRow? {
        guard let row = pending.removeValue(forKey: id) else { return nil }
        pendingOrder.removeValue(forKey: id)
        visible[id] = row
        emissions.append(now)
        return row
    }
}
