// SPDX-License-Identifier: MIT

import Foundation

public actor CircuitBreaker {
    private struct ConnectorState: Codable {
        var operationDates: [Date] = []
        var consecutiveProviderFailures = 0
        var unknownOperationIDs: Set<UUID> = []
        var revoked = false
    }

    private let fileURL: URL
    private var states: [String: ConnectorState]
    private let failureThreshold: Int

    public init(root: URL, failureThreshold: Int = 3) throws {
        fileURL = root.appendingPathComponent("op/circuit-breaker.json")
        states = try S4Persistence.load([String: ConnectorState].self, from: fileURL) ?? [:]
        self.failureThreshold = max(1, failureThreshold)
    }

    public func checkGrant(connectorID: String, grant: ConnectorGrant) -> GateDenial? {
        let state = states[connectorID] ?? ConnectorState()
        if state.revoked || grant.version <= 0 {
            return GateDenial(code: "grant_expired_or_revoked", message: "授权已过期或撤销；请在连接器设置中恢复授权")
        }
        return nil
    }

    public func check(connectorID: String, grant: ConnectorGrant, now: Date = Date()) -> GateDenial? {
        if let denial = checkGrant(connectorID: connectorID, grant: grant) { return denial }
        let state = states[connectorID] ?? ConnectorState()
        if state.consecutiveProviderFailures >= failureThreshold {
            return GateDenial(code: "provider_failure_breaker", message: "服务连续失败；请检查连接后恢复")
        }
        if !state.unknownOperationIDs.isEmpty {
            return GateDenial(code: "unknown_operation_pending", message: "有操作仍待对账；请先确认最终结果")
        }
        let recent = state.operationDates.filter { now.timeIntervalSince($0) < 3_600 }
        if recent.count >= grant.rateLimit.maxOperationsPerHour {
            return GateDenial(code: "rate_limit_exceeded", message: "已超出授权频率；请稍后重试或调整授权")
        }
        return nil
    }

    public func recordOperation(connectorID: String, at date: Date = Date()) throws {
        var state = states[connectorID] ?? ConnectorState()
        state.operationDates = state.operationDates.filter { date.timeIntervalSince($0) < 3_600 } + [date]
        try update(connectorID, state)
    }

    public func recordProviderFailure(connectorID: String) throws {
        var state = states[connectorID] ?? ConnectorState()
        state.consecutiveProviderFailures += 1
        try update(connectorID, state)
    }

    public func recordProviderSuccess(connectorID: String) throws {
        var state = states[connectorID] ?? ConnectorState()
        state.consecutiveProviderFailures = 0
        try update(connectorID, state)
    }

    public func setUnknown(connectorID: String, operationID: UUID, isUnknown: Bool) throws {
        var state = states[connectorID] ?? ConnectorState()
        if isUnknown {
            state.unknownOperationIDs.insert(operationID)
        } else {
            state.unknownOperationIDs.remove(operationID)
        }
        try update(connectorID, state)
    }

    public func revoke(connectorID: String) throws {
        var state = states[connectorID] ?? ConnectorState()
        state.revoked = true
        try update(connectorID, state)
    }

    public func restore(connectorID: String) throws {
        var state = states[connectorID] ?? ConnectorState()
        state.revoked = false
        state.consecutiveProviderFailures = 0
        try update(connectorID, state)
    }

    public func consecutiveFailures(connectorID: String) -> Int {
        states[connectorID]?.consecutiveProviderFailures ?? 0
    }

    public func unknownOperationIDs(connectorID: String) -> Set<UUID> {
        states[connectorID]?.unknownOperationIDs ?? []
    }

    private func update(_ connectorID: String, _ state: ConnectorState) throws {
        var updated = states
        updated[connectorID] = state
        try S4Persistence.save(updated, to: fileURL)
        states = updated
    }
}
