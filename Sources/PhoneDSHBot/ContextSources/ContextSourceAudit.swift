// SPDX-License-Identifier: MIT

import Foundation

/// One host audit record for context-source consent/observation decisions.
///
/// The durable form is the G-3 `context.consent_changed`/`context.observed`
/// event; this value is the in-module record the registry emits and tests
/// assert. It never contains a payload, a credential or a personal datum.
public struct BotContextAuditEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case consentChanged = "context.consent_changed"
        case observationRejected = "context.observation_rejected"
        case observationAccepted = "context.observation_accepted"
        case sourceFailed = "context.source_failed"
        case wakeEmitted = "context.wake_emitted"
        case wakeSuppressed = "context.wake_suppressed"
    }

    public var kind: Kind
    public var source: BotContextSourceKind?
    public var ownerBotID: String?
    public var at: Int64
    public var permissionRevision: Int
    public var detail: String
    public var previous: BotSourceAuthorization?
    public var current: BotSourceAuthorization?
    public var uncertainty: BotContextUncertainty?
    public var observationID: String?
    public var by: BotSourceAuthorizationActor?
    public var osState: BotSourceAuthorization?

    public init(kind: Kind, source: BotContextSourceKind? = nil,
                ownerBotID: String? = nil, at: Int64,
                permissionRevision: Int, detail: String,
                previous: BotSourceAuthorization? = nil,
                current: BotSourceAuthorization? = nil,
                uncertainty: BotContextUncertainty? = nil,
                observationID: String? = nil,
                by: BotSourceAuthorizationActor? = nil,
                osState: BotSourceAuthorization? = nil) {
        self.kind = kind
        self.source = source
        self.ownerBotID = ownerBotID
        self.at = max(0, at)
        self.permissionRevision = max(0, permissionRevision)
        self.detail = String(detail.prefix(300))
        self.previous = previous
        self.current = current
        self.uncertainty = uncertainty
        self.observationID = observationID.map { String($0.prefix(200)) }
        self.by = by
        self.osState = osState
    }

    public var generation: Int { permissionRevision }
}

public protocol BotContextAuditRecording: Sendable {
    func record(_ event: BotContextAuditEvent) async
}

/// Bounded in-memory audit used by unit tests and the App diagnostics surface.
/// The durable `context.*` event writer is added only after G-3 freezes the P25
/// type/field rules; this actor never pretends to be that writer.
public actor BotContextAuditLog: BotContextAuditRecording {
    public static let maximumEvents = 500
    private var events: [BotContextAuditEvent] = []

    public init(events: [BotContextAuditEvent] = []) {
        self.events = Array(events.suffix(Self.maximumEvents))
    }

    public func record(_ event: BotContextAuditEvent) {
        events.append(event)
        if events.count > Self.maximumEvents {
            events.removeFirst(events.count - Self.maximumEvents)
        }
    }

    public func snapshot() -> [BotContextAuditEvent] { events }

    public func recent(limit: Int = 50) -> [BotContextAuditEvent] {
        Array(events.suffix(max(0, limit)))
    }
}
