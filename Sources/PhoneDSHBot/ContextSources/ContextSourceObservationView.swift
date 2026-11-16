// SPDX-License-Identifier: MIT

import Foundation

/// One read-view item. It deliberately has no `payload`/body: an active item
/// carries the durable `record_ref` instead, so a caller re-reads the original
/// through the authorized record path. A revoked/stale item is `inactive` and
/// carries no content.
public struct BotContextObservationViewItem: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case active
        case inactive
    }

    public enum InactiveReason: String, Codable, Sendable {
        case revoked
        case generationMismatch = "generation-mismatch"
        case erased
        case expired
    }

    public var source: BotContextSourceKind
    public var kind: String
    public var observedAtMS: Int64
    public var sourceVersion: BotContextSourceVersion
    public var uncertainty: BotContextUncertainty
    public var recordRef: String?
    public var state: State
    public var inactiveReason: InactiveReason?
    public var consentGeneration: Int

    public init(source: BotContextSourceKind, kind: String, observedAtMS: Int64,
                sourceVersion: BotContextSourceVersion,
                uncertainty: BotContextUncertainty,
                recordRef: String?, state: State,
                inactiveReason: InactiveReason? = nil,
                consentGeneration: Int) {
        self.source = source
        self.kind = kind
        self.observedAtMS = observedAtMS
        self.sourceVersion = sourceVersion
        self.uncertainty = uncertainty
        self.recordRef = recordRef
        self.state = state
        self.inactiveReason = inactiveReason
        self.consentGeneration = consentGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case source, kind, observed_at_ms, source_version, uncertainty, record_ref
        case state, inactive_reason, consent_generation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(BotContextSourceKind.self, forKey: .source)
        kind = try container.decode(String.self, forKey: .kind)
        observedAtMS = try container.decode(Int64.self, forKey: .observed_at_ms)
        sourceVersion = try container.decode(BotContextSourceVersion.self, forKey: .source_version)
        uncertainty = try container.decode(BotContextUncertainty.self, forKey: .uncertainty)
        recordRef = try container.decodeIfPresent(String.self, forKey: .record_ref)
        state = try container.decode(State.self, forKey: .state)
        inactiveReason = try container.decodeIfPresent(InactiveReason.self, forKey: .inactive_reason)
        consentGeneration = try container.decode(Int.self, forKey: .consent_generation)
        if state == .active, inactiveReason != nil {
            throw DecodingError.dataCorruptedError(
                forKey: .inactive_reason, in: container,
                debugDescription: "an active item cannot carry an inactive reason")
        }
        if state == .inactive, inactiveReason == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .inactive_reason, in: container,
                debugDescription: "an inactive item must carry an inactive reason")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(kind, forKey: .kind)
        try container.encode(observedAtMS, forKey: .observed_at_ms)
        try container.encode(sourceVersion, forKey: .source_version)
        try container.encode(uncertainty, forKey: .uncertainty)
        try container.encodeIfPresent(recordRef, forKey: .record_ref)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(inactiveReason, forKey: .inactive_reason)
        try container.encode(consentGeneration, forKey: .consent_generation)
    }
}

/// Read-time view for one Bot. Only the current consent generation and
/// authorized/limited consent is active. It is a snapshot; it never mixes a new
/// event append into an older generation.
public struct BotContextObservationView: Codable, Sendable, Equatable {
    public var botID: String
    public var consentGeneration: Int
    public var items: [BotContextObservationViewItem]

    public init(botID: String, consentGeneration: Int,
                items: [BotContextObservationViewItem]) {
        self.botID = botID
        self.consentGeneration = max(0, consentGeneration)
        self.items = Array(items.prefix(50))
    }

    private enum CodingKeys: String, CodingKey {
        case bot_id, consent_generation, items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        botID = try container.decode(String.self, forKey: .bot_id)
        consentGeneration = try container.decode(Int.self, forKey: .consent_generation)
        items = try container.decode([BotContextObservationViewItem].self, forKey: .items)
        guard items.count <= 50 else {
            throw DecodingError.dataCorruptedError(
                forKey: .items, in: container,
                debugDescription: "context view exceeds 50 items")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(botID, forKey: .bot_id)
        try container.encode(consentGeneration, forKey: .consent_generation)
        try container.encode(items, forKey: .items)
    }
}
