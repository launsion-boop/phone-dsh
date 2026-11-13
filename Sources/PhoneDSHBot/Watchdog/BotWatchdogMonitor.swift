// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public actor BotWatchdogMonitor {
    private struct UnitKey: Hashable, Sendable {
        let kind: BotWatchdogUnitKind
        let id: String
    }

    private struct SeenKey: Hashable, Sendable {
        let unit: UnitKey
        let check: BotWatchdogCheck
    }

    private struct TrackedUnit {
        var state: BotWatchdogUnit
        var deadlineMs: Int64
        var pendingCalls: [String: String] = [:]
    }

    private let eventLog: any BotEventLog
    private let config: BotWatchdogConfig
    private let clock: @Sendable () -> Int64
    private let log: @Sendable (String) -> Void
    private var units: [UnitKey: TrackedUnit] = [:]
    private var pending: Set<SeenKey> = []
    private var seen: Set<SeenKey> = []
    private var recentFlags: [BotWatchdogFlag] = []

    public init(
        eventLog: any BotEventLog,
        config: BotWatchdogConfig = .default,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.eventLog = eventLog
        self.config = config
        self.clock = now
        self.log = log
    }

    @discardableResult
    public func startUnit(
        kind: BotWatchdogUnitKind,
        id: String,
        botId: String? = nil,
        sessionId: String? = nil,
        startedAt: Int64? = nil,
        deadlineOverrideMs: Int64? = nil,
        at: Int64? = nil
    ) async -> [BotWatchdogFlag] {
        let unitId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unitId.isEmpty else { return [] }
        let now = at ?? clock()
        let key = UnitKey(kind: kind, id: unitId)
        if var existing = units[key] {
            if existing.state.botId == nil { existing.state.botId = botId }
            if existing.state.sessionId == nil { existing.state.sessionId = sessionId }
            existing.state.lastEventAt = max(existing.state.lastEventAt ?? now, now)
            units[key] = existing
            return await evaluate(key: key, now: now)
        }
        evictIfNeeded()
        let start = startedAt ?? now
        let deadlineMs = config.deadlineMs(for: kind, override: deadlineOverrideMs)
        let state = BotWatchdogUnit(
            kind: kind, id: unitId, botId: botId, sessionId: sessionId,
            startedAt: start, lastEventAt: now,
            deadlineAt: deadlineMs > 0 ? start + deadlineMs : nil)
        units[key] = TrackedUnit(state: state, deadlineMs: deadlineMs)
        return await evaluate(key: key, now: now)
    }

    public func finishUnit(kind: BotWatchdogUnitKind, id: String) {
        let key = UnitKey(kind: kind, id: id)
        units.removeValue(forKey: key)
        seen = seen.filter { $0.unit != key }
    }

    public func unit(kind: BotWatchdogUnitKind, id: String) -> BotWatchdogUnit? {
        units[UnitKey(kind: kind, id: id)]?.state
    }

    @discardableResult
    public func observeActivity(
        kind: BotWatchdogUnitKind,
        id: String,
        at: Int64? = nil
    ) async -> [BotWatchdogFlag] {
        let now = at ?? clock()
        let key = UnitKey(kind: kind, id: id)
        guard var tracked = units[key] else { return [] }
        tracked.state.lastEventAt = max(tracked.state.lastEventAt ?? now, now)
        units[key] = tracked
        return await evaluate(key: key, now: now)
    }

    @discardableResult
    public func observeApproval(
        kind: BotWatchdogUnitKind,
        id: String,
        requested: Bool,
        at: Int64? = nil
    ) async -> [BotWatchdogFlag] {
        let key = UnitKey(kind: kind, id: id)
        guard var tracked = units[key] else { return [] }
        tracked.state.pendingApproval = max(0, tracked.state.pendingApproval + (requested ? 1 : -1))
        units[key] = tracked
        return await observeActivity(kind: kind, id: id, at: at)
    }

    @discardableResult
    public func observeToolCall(
        kind: BotWatchdogUnitKind,
        id: String,
        name: String,
        argumentsDigest: String? = nil,
        callId: String? = nil,
        at: Int64? = nil
    ) async -> [BotWatchdogFlag] {
        let key = UnitKey(kind: kind, id: id)
        guard var tracked = units[key] else { return [] }
        let signature = argumentsDigest?.isEmpty == false ? "\(name)|\(argumentsDigest!)" : name
        if signature == tracked.state.lastToolSignature {
            tracked.state.repeatedToolSignatureCount += 1
        } else {
            tracked.state.lastToolSignature = signature
            tracked.state.repeatedToolSignatureCount = 1
        }
        if let callId, !callId.isEmpty {
            tracked.pendingCalls[callId] = name
            while tracked.pendingCalls.count > 200 {
                if let oldest = tracked.pendingCalls.keys.sorted().first {
                    tracked.pendingCalls.removeValue(forKey: oldest)
                }
            }
        }
        units[key] = tracked
        return await observeActivity(kind: kind, id: id, at: at)
    }

    @discardableResult
    public func observeToolResult(
        kind: BotWatchdogUnitKind,
        id: String,
        name: String? = nil,
        status: String,
        error: String? = nil,
        resultDigest: String? = nil,
        callId: String? = nil,
        at: Int64? = nil
    ) async -> [BotWatchdogFlag] {
        let key = UnitKey(kind: kind, id: id)
        guard var tracked = units[key] else { return [] }
        let pendingName = callId.flatMap { tracked.pendingCalls[$0] }
        if let callId { tracked.pendingCalls.removeValue(forKey: callId) }
        let toolName = pendingName ?? name ?? "unknown"
        if status.lowercased() == "error" {
            let errorText = error ?? resultDigest ?? "error"
            let signature = "\(toolName)|\(Self.sha256(errorText))"
            if signature == tracked.state.lastToolErrorSignature {
                tracked.state.repeatedToolErrorCount += 1
            } else {
                tracked.state.lastToolErrorSignature = signature
                tracked.state.repeatedToolErrorCount = 1
            }
        } else {
            tracked.state.lastToolErrorSignature = nil
            tracked.state.repeatedToolErrorCount = 0
        }
        units[key] = tracked
        return await observeActivity(kind: kind, id: id, at: at)
    }

    @discardableResult
    public func observeUsage(
        kind: BotWatchdogUnitKind,
        id: String,
        tokens: Int = 0,
        costUsd: Double = 0,
        at: Int64? = nil
    ) async -> [BotWatchdogFlag] {
        let key = UnitKey(kind: kind, id: id)
        guard var tracked = units[key] else { return [] }
        if tokens > 0 { tracked.state.tokens += tokens }
        if costUsd.isFinite, costUsd > 0 { tracked.state.costUsd += costUsd }
        units[key] = tracked
        return await observeActivity(kind: kind, id: id, at: at)
    }

    @discardableResult
    public func observeMobile(
        _ event: BotMobileWatchdogEvent,
        kind: BotWatchdogUnitKind,
        id: String,
        botId: String? = nil,
        sessionId: String? = nil,
        evidence: [String: BotJSONValue] = [:],
        at: Int64? = nil
    ) async -> [BotWatchdogFlag] {
        let now = at ?? clock()
        let finding = BotWatchdogFinding(check: event.check, evidence: evidence)
        if let flag = await emit(
            unitKind: kind, unitId: id, botId: botId, sessionId: sessionId,
            finding: finding, at: now) {
            return [flag]
        }
        return []
    }

    @discardableResult
    public func tick(at: Int64? = nil) async -> [BotWatchdogFlag] {
        let now = at ?? clock()
        var flags: [BotWatchdogFlag] = []
        for key in units.keys.sorted(by: { "\($0.kind.rawValue)\0\($0.id)" < "\($1.kind.rawValue)\0\($1.id)" }) {
            flags.append(contentsOf: await evaluate(key: key, now: now))
        }
        return flags
    }

    public func hasFlagged(kind: BotWatchdogUnitKind, id: String, check: BotWatchdogCheck) -> Bool {
        seen.contains(SeenKey(unit: UnitKey(kind: kind, id: id), check: check))
    }

    public func flags(limit: Int = 50) -> [BotWatchdogFlag] {
        Array(recentFlags.prefix(max(0, min(limit, config.historyLimit))))
    }

    private func evaluate(key: UnitKey, now: Int64) async -> [BotWatchdogFlag] {
        guard let tracked = units[key] else { return [] }
        let findings = BotWatchdogChecks.run(unit: tracked.state, now: now, config: config)
        var flags: [BotWatchdogFlag] = []
        for finding in findings {
            if let flag = await emit(
                unitKind: key.kind, unitId: key.id, botId: tracked.state.botId,
                sessionId: tracked.state.sessionId, finding: finding, at: now) {
                flags.append(flag)
            }
        }
        return flags
    }

    private func emit(
        unitKind: BotWatchdogUnitKind,
        unitId: String,
        botId: String?,
        sessionId: String?,
        finding: BotWatchdogFinding,
        at: Int64
    ) async -> BotWatchdogFlag? {
        let trimmedId = unitId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return nil }
        let seenKey = SeenKey(unit: UnitKey(kind: unitKind, id: trimmedId), check: finding.check)
        guard !seen.contains(seenKey), !pending.contains(seenKey) else { return nil }
        pending.insert(seenKey)
        defer { pending.remove(seenKey) }
        let eventId = Self.eventId(kind: unitKind, id: trimmedId, check: finding.check)
        let event = BotEvent(
            type: "watchdog.flagged",
            eventId: eventId,
            time: at,
            origin: .local(source: "watchdog"),
            traceId: "trace:watchdog:\(eventId)",
            principal: BotPrincipal(
                botId: botId, sessionId: sessionId, kind: "watchdog"),
            causationId: nil,
            correlationId: trimmedId,
            data: .object([
                "unitKind": .string(unitKind.rawValue),
                "unitId": .string(trimmedId),
                "botId": botWatchdogString(botId),
                "sessionId": botWatchdogString(sessionId),
                "check": .string(finding.check.rawValue),
                "at": botWatchdogNumber(at),
                "evidence": finding.evidence,
            ]))
        do {
            if try await Self.hasCommittedEvent(eventId: eventId, eventLog: eventLog) {
                seen.insert(seenKey)
                return nil
            }
            let commitSeq = try await eventLog.append(event)
            seen.insert(seenKey)
            let flag = BotWatchdogFlag(
                unitKind: unitKind, unitId: trimmedId, botId: botId,
                sessionId: sessionId, check: finding.check, evidence: finding.evidence,
                at: at, eventId: eventId, commitSeq: commitSeq)
            recentFlags.insert(flag, at: 0)
            if recentFlags.count > max(1, config.historyLimit) {
                recentFlags.removeLast()
            }
            return flag
        } catch {
            log("watchdog flag publish failed (\(unitKind.rawValue)/\(trimmedId)/\(finding.check.rawValue)): \(error)")
            return nil
        }
    }

    private static func hasCommittedEvent(eventId: String, eventLog: any BotEventLog) async throws -> Bool {
        if let store = eventLog as? SQLiteDomainStore {
            return try await store.event(withId: eventId) != nil
        }
        var cursor = 0
        while true {
            let events = try await eventLog.events(after: cursor, limit: 1_000)
            if events.isEmpty { return false }
            for event in events {
                if event.eventId == eventId { return true }
                if let commitSeq = event.commitSeq { cursor = max(cursor, commitSeq) }
            }
            if events.count < 1_000 { return false }
        }
    }

    private func evictIfNeeded() {
        while units.count >= max(1, config.maxUnits) {
            guard let oldest = units.min(by: {
                ($0.value.state.lastEventAt ?? $0.value.state.startedAt)
                    < ($1.value.state.lastEventAt ?? $1.value.state.startedAt)
            }) else { return }
            units.removeValue(forKey: oldest.key)
        }
    }

    private static func eventId(kind: BotWatchdogUnitKind, id: String, check: BotWatchdogCheck) -> String {
        let raw = "watchdog.flagged:\(kind.rawValue):\(id):\(check.rawValue)"
        if raw.count <= 400 { return raw }
        let digest = String(sha256(raw).replacingOccurrences(of: "sha256:", with: "").prefix(32))
        return "watchdog.flagged:\(kind.rawValue):\(digest):\(check.rawValue)"
    }

    private static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "sha256:\(digest)"
    }
}
