// SPDX-License-Identifier: MIT

import Foundation

/// One observation after its durable record was appended. `recordRef` is the
/// canonical `record://event/<commitSeq>` the read view and the model can use to
/// re-read the original payload; the view itself never copies the payload.
public struct BotContextRecordedObservation: Sendable, Equatable {
    public var observationID: String
    public var ownerBotID: String
    public var recordRef: String

    public init(observationID: String, ownerBotID: String, recordRef: String) {
        self.observationID = observationID
        self.ownerBotID = ownerBotID
        self.recordRef = recordRef
    }
}

public protocol BotContextObservationRecording: Sendable {
    func record(_ observation: BotContextObservation,
                ownerBotID: String) async -> BotContextRecordedObservation?
}

public protocol BotContextConsentRecording: Sendable {
    func record(_ event: BotContextAuditEvent) async
}

/// Writes the two additive durable event types frozen by G-3:
/// `context.observed` and `context.consent_changed`.
///
/// Both are `ignorable:true`, reuse `origin.kind=local, source=runtime` and
/// `principal.kind=proactive`; no new origin/principal enum value is invented.
/// A rejected/failed append returns nil and leaves the in-memory audit as the
/// only record; it never fabricates a `record://` reference.
public actor BotContextDurableWriter: BotContextObservationRecording, BotContextConsentRecording {
    public static let observationType = "context.observed"
    public static let consentType = "context.consent_changed"

    private let eventLog: any BotEventLog
    private let now: @Sendable () -> Int64

    public init(eventLog: any BotEventLog,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.eventLog = eventLog
        self.now = now
    }

    public func record(_ observation: BotContextObservation,
                       ownerBotID: String) async -> BotContextRecordedObservation? {
        guard let data = try? observation.eventData(ownerBotID: ownerBotID) else { return nil }
        let event = BotEvent(
            type: Self.observationType,
            eventId: "context-observed:\(ownerBotID):\(observation.id)",
            time: observation.observedAt,
            origin: .local(source: "runtime"),
            traceId: "trace-context-\(UUID().uuidString.lowercased())",
            principal: BotPrincipal(botId: ownerBotID, sessionId: nil, kind: "proactive"),
            causationId: nil,
            correlationId: observation.dedupeKey,
            ignorable: true,
            data: data)
        guard let seq = try? await eventLog.append(event),
              seq >= 1 else { return nil }
        return BotContextRecordedObservation(
            observationID: observation.id, ownerBotID: ownerBotID,
            recordRef: "record://event/\(seq)")
    }

    /// Writes the consent audit event. The caller supplies the transition
    /// fields from the ledger; missing OS state falls back to notDetermined.
    public func record(_ audit: BotContextAuditEvent) async {
        guard audit.kind == .consentChanged,
              let source = audit.source,
              let previous = audit.previous,
              let current = audit.current else { return }
        let osState: BotSourceAuthorization = {
            guard let value = audit.osState, value != .revoked else { return .notDetermined }
            return value
        }()
        let reason = audit.detail.isEmpty ? nil : String(audit.detail.prefix(120))
        var data: [String: BotJSONValue] = [
            "schema": .string("bot-context-consent-changed/v1"),
            "source": .string(source.rawValue),
            "generation": .number(Double(max(1, audit.permissionRevision))),
            "previous": .string(previous.rawValue),
            "consent": .string(current.rawValue),
            "os_state": .string(osState.rawValue),
            "by": .string((audit.by ?? .system).rawValue),
            "at_ms": .number(Double(audit.at)),
        ]
        if let owner = audit.ownerBotID, !owner.isEmpty {
            data["owner_bot_id"] = .string(String(owner.prefix(128)))
        }
        if let reason {
            data["reason"] = .string(reason)
        }
        let event = BotEvent(
            type: Self.consentType,
            eventId: "context-consent:\(source.rawValue):\(audit.permissionRevision)",
            time: audit.at,
            origin: .local(source: "runtime"),
            traceId: "trace-context-consent-\(UUID().uuidString.lowercased())",
            principal: BotPrincipal(botId: audit.ownerBotID, sessionId: nil, kind: "proactive"),
            causationId: nil,
            correlationId: nil,
            ignorable: true,
            data: .object(data))
        _ = try? await eventLog.append(event)
    }
}
